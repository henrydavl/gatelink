package com.example.gatelink.vpn

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.IpPrefix
import android.net.VpnService
import android.net.http.X509TrustManagerExtensions
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.example.gatelink.MainActivity
import java.net.InetAddress
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.infradead.libopenconnect.LibOpenConnect

sealed interface VpnState {
    data object Idle : VpnState
    data object Authenticating : VpnState
    data object Connecting : VpnState
    data class Connected(val host: String, val sinceMillis: Long) : VpnState
    data object Disconnecting : VpnState
    data class Failed(val reason: String) : VpnState
}

/**
 * Runs one GlobalProtect session with libopenconnect: logs in to the gateway
 * with password + OTP (as `--usergroup=gateway`), then tunnels through
 * Android's VPN interface with the gateway's routes and DNS.
 */
class GateLinkVpnService : VpnService() {
    private data class Request(val host: String, val username: String, val credential: String)

    @Volatile private var client: Client? = null
    @Volatile private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> {
                stopping = true
                client?.cancel()
                if (client == null) stopSelf()
            }
            ACTION_CONNECT -> {
                val request = synchronized(Companion) { pending.also { pending = null } }
                if (request == null || client != null) return START_NOT_STICKY
                stopping = false
                Thread({ run(request) }, "openconnect").start()
            }
            // Always-on VPN or a restart: only the app can log in (it needs the OTP).
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopping = true
        client?.cancel()
    }

    private fun run(request: Request) {
        val oc = Client(request)
        client = oc
        var tun: ParcelFileDescriptor? = null
        try {
            _state.value = VpnState.Authenticating
            oc.setLogLevel(LibOpenConnect.PRG_INFO)
            oc.setSystemTrust(false)  // the bundled OpenSSL has no CA store; onValidatePeerCert decides
            if (oc.setProtocol("gp") != 0 || oc.parseURL("https://${request.host}") != 0) fail(oc, "Could not set up OpenConnect.")
            oc.setUrlpath("gateway")  // --usergroup=gateway: the portal endpoint loops with HTTP 512
            oc.disableDTLS()          // same as --no-dtls on macOS
            if (oc.obtainCookie() != 0) fail(oc, "Login failed. Check the username, password and OTP.")

            _state.value = VpnState.Connecting
            if (oc.makeCSTPConnection() != 0) fail(oc, "The tunnel did not come up.")
            tun = configure(oc.ipInfo ?: fail(oc, "The gateway did not assign an address."), request.host)
                ?: fail(oc, "Android did not allow the VPN. Open GateLink and press Connect.")
            if (oc.setupTunFD(tun.fd) != 0) fail(oc, "Could not attach to the VPN interface.")

            _state.value = VpnState.Connected(request.host, System.currentTimeMillis())
            oc.firstError = null
            // 0 means paused; keep going. Reconnects for up to 5 minutes, like macOS.
            var ret: Int
            do { ret = oc.mainloop(300, LibOpenConnect.RECONNECT_INTERVAL_MIN) } while (ret == 0)
            _state.value = if (stopping) VpnState.Idle else VpnState.Failed(oc.firstError ?: "The VPN connection was lost.")
        } catch (e: TunnelFailure) {
            _state.value = if (stopping) VpnState.Idle else VpnState.Failed(e.message ?: "The VPN connection failed.")
        } finally {
            tun?.close()
            client = null
            oc.destroy()
            stopSelf()
        }
    }

    private class TunnelFailure(message: String) : Exception(message)

    private fun fail(oc: Client, fallback: String): Nothing = throw TunnelFailure(oc.firstError ?: fallback)

    /** The gateway's addresses, split routes and DNS; no split routes means everything is tunnelled. */
    private fun configure(info: LibOpenConnect.IPInfo, host: String): ParcelFileDescriptor? {
        val builder = Builder().setSession("GateLink")
        if (info.MTU > 0) builder.setMtu(info.MTU)
        info.addr?.let { builder.addAddress(it, Network.prefixLength(info.netmask)) }
        (info.netmask6 ?: info.addr6)?.let { Network.route(it) }?.let { (addr, prefix) -> builder.addAddress(addr, prefix) }

        val includes = info.splitIncludes.mapNotNull { Network.route(it) }
        if (includes.isEmpty()) {
            if (info.addr != null) builder.addRoute("0.0.0.0", 0)
            if (info.addr6 != null || info.netmask6 != null) builder.addRoute("::", 0)
        } else {
            includes.forEach { (addr, prefix) -> builder.addRoute(addr, prefix) }
        }
        if (Build.VERSION.SDK_INT >= 33) {
            info.splitExcludes.mapNotNull { Network.route(it) }.forEach { (addr, prefix) ->
                builder.excludeRoute(IpPrefix(InetAddress.getByName(addr), prefix))
            }
        }
        info.DNS.forEach { builder.addDnsServer(it) }
        info.domain?.split(' ', ',')?.filter { it.isNotBlank() }?.forEach { builder.addSearchDomain(it) }
        builder.setConfigureIntent(
            PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE),
        )
        return builder.establish()
    }

    /** libopenconnect callbacks for one session. */
    private inner class Client(private val request: Request) : LibOpenConnect("AnyConnect-compatible OpenConnect VPN Agent") {
        @Volatile var firstError: String? = null
        private var answered = false

        private fun error(message: String) {
            if (firstError == null) firstError = message
        }

        override fun onProgress(level: Int, msg: String) {
            val line = msg.trimEnd()
            if (level == PRG_ERR) error(line)
            Log.println(if (level == PRG_ERR) Log.WARN else Log.INFO, TAG, line)
        }

        /** Username into user* / uname* fields, password + OTP into the password field. A
         *  second password prompt means the gateway rejected it, as on macOS. */
        override fun onProcessAuthForm(authForm: AuthForm): Int {
            authForm.error?.let { error(it) }
            for (opt in authForm.opts) {
                if (opt.flags and OC_FORM_OPT_IGNORE.toLong() != 0L) continue
                when (opt.type) {
                    OC_FORM_OPT_TEXT -> {
                        val name = opt.name.lowercase()
                        if (!name.startsWith("user") && !name.startsWith("uname")) {
                            error("The gateway asked for a field GateLink cannot fill.")
                            return OC_FORM_RESULT_CANCELLED
                        }
                        opt.value = request.username
                    }
                    OC_FORM_OPT_PASSWORD -> {
                        if (answered) {
                            error("Login failed: the gateway asked for the password again. Check the password and OTP.")
                            return OC_FORM_RESULT_CANCELLED
                        }
                        opt.value = request.credential
                        answered = true
                    }
                }
            }
            return OC_FORM_RESULT_OK
        }

        /** Trust what Android trusts, for the portal name the user typed: on NAT64
         *  networks openconnect's own hostname becomes the gateway's IPv6 address. */
        override fun onValidatePeerCert(msg: String?): Int {
            val chain = peerCertChain?.map {
                CertificateFactory.getInstance("X.509").generateCertificate(it.inputStream()) as X509Certificate
            }?.toTypedArray()
            if (chain.isNullOrEmpty()) {
                error("The gateway sent no certificate.")
                return 1
            }
            return try {
                val authType = if (chain[0].publicKey.algorithm == "EC") "ECDHE_ECDSA" else "ECDHE_RSA"
                X509TrustManagerExtensions(systemTrustManager).checkServerTrusted(chain, authType, request.host)
                val names = chain[0].subjectAlternativeNames.orEmpty().filter { it[0] == 2 }.map { it[1] as String }
                if (names.none { Network.nameMatches(it, request.host) }) {
                    error("The gateway's certificate is not for ${request.host}.")
                    1
                } else {
                    0
                }
            } catch (e: Exception) {
                error("Android does not trust the certificate ${request.host} presented: ${e.message}")
                1
            }
        }

        override fun onProtectSocket(fd: Int) {
            // The connection to the gateway itself must not go through the tunnel.
            protect(fd)
        }
    }

    companion object {
        private const val TAG = "GateLink"
        private const val ACTION_CONNECT = "com.example.gatelink.CONNECT"
        private const val ACTION_DISCONNECT = "com.example.gatelink.DISCONNECT"

        private val _state = MutableStateFlow<VpnState>(VpnState.Idle)
        val state: StateFlow<VpnState> = _state

        // The credential stays in this process; it never travels in an Intent.
        private var pending: Request? = null

        init {
            System.loadLibrary("openconnect")
        }

        private val systemTrustManager: X509TrustManager by lazy {
            TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).run {
                init(null as KeyStore?)
                trustManagers.filterIsInstance<X509TrustManager>().first()
            }
        }

        /** Call after VpnService.prepare() has been granted. */
        fun connect(context: Context, host: String, username: String, credential: String) {
            synchronized(this) { pending = Request(host, username, credential) }
            _state.value = VpnState.Authenticating
            context.startService(Intent(context, GateLinkVpnService::class.java).setAction(ACTION_CONNECT))
        }

        fun disconnect(context: Context) {
            if (_state.value is VpnState.Connected) _state.value = VpnState.Disconnecting
            context.startService(Intent(context, GateLinkVpnService::class.java).setAction(ACTION_DISCONNECT))
        }

        /** Shows a failure that happened before the service started (e.g. a locked vault). */
        fun reportFailure(reason: String) {
            _state.value = VpnState.Failed(reason)
        }

        fun resetIfIdle() {
            if (_state.value is VpnState.Failed) _state.value = VpnState.Idle
        }
    }
}
