package com.example.gatelink

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.gatelink.otp.Totp
import com.example.gatelink.vault.Account
import com.example.gatelink.vault.AccountDraft
import com.example.gatelink.vault.Vault
import com.example.gatelink.vault.VaultLockedException
import com.example.gatelink.vpn.GateLinkVpnService
import com.example.gatelink.vpn.Network
import com.example.gatelink.vpn.VpnState
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** What the Activity does for the model: unlock prompts and the VPN permission dialog. */
interface Platform {
    suspend fun unlock(reason: String): Boolean
    suspend fun allowVpn(): Boolean
}

/** App state for the screen; the Android counterpart of the macOS/iOS AppModel. */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    val vault = Vault(application.filesDir)
    val vpnState: StateFlow<VpnState> = GateLinkVpnService.state
    var platform: Platform? = null

    var selectedId by mutableStateOf<String?>(null)
        private set
    var gateway by mutableStateOf("")
    /** Feedback that is not part of the connection state. */
    var message by mutableStateOf<String?>(null)
    /** Generator for the visible code; dropped when the unlock window ends. */
    var revealed by mutableStateOf<Totp?>(null)
        private set

    var username by mutableStateOf("")
        private set

    private val prefs = application.getSharedPreferences("gatelink", Context.MODE_PRIVATE)
    private var unlockedUntil = 0L
    private var lastCounter: Long? = null

    init {
        try {
            vault.load()
        } catch (e: Exception) {
            message = e.message
        }
        gateway = prefs.getString("gateway", "").orEmpty()
        selectedId = prefs.getString("selectedAccount", null)
        account?.let { username = it.username }
        viewModelScope.launch {
            while (true) {
                delay(1_000)
                if (revealed != null && System.currentTimeMillis() > unlockedUntil) revealed = null
            }
        }
    }

    // MARK: Accounts

    val account: Account? get() = vault.accounts.value.let { list -> list.firstOrNull { it.id == selectedId } ?: list.firstOrNull() }

    val canSwitchAccount get() = vpnState.value.let { it is VpnState.Idle || it is VpnState.Failed }

    /** Typing another account's username switches to that account, so its OTP is used. */
    fun updateUsername(value: String) {
        username = value
        vault.accountForUsername(value, preferring = selectedId)?.let { if (it.id != selectedId) setSelection(it.id) }
    }

    fun select(account: Account) {
        setSelection(account.id)
        username = account.username
    }

    private fun setSelection(id: String) {
        selectedId = id
        prefs.edit().putString("selectedAccount", id).apply()
        revealed = null
    }

    /** Returns false if the unlock was cancelled. */
    suspend fun add(draft: AccountDraft): Boolean {
        withUnlock("Save the ${draft.account.issuer} account") { vault.add(draft) } ?: return false
        select(draft.account)
        message = "Added ${draft.account.issuer}."
        return true
    }

    fun deleteCurrentAccount() {
        val account = account ?: return
        vault.delete(account)
        revealed = null
        vault.accounts.value.firstOrNull()?.let { select(it) } ?: run { username = "" }
        message = "Deleted ${account.issuer}."
    }

    suspend fun savePassword(password: String): Boolean {
        val account = account ?: return false
        return try {
            withUnlock("Save the VPN password for ${account.username}") { vault.setPassword(account, password) } ?: return false
            message = "Password saved."
            true
        } catch (e: Exception) {
            message = e.message
            false
        }
    }

    // MARK: Code

    fun toggleReveal() = viewModelScope.launch {
        if (revealed != null) {
            revealed = null
            return@launch
        }
        val account = account ?: return@launch
        try {
            revealed = withUnlock("Show the ${account.issuer} code") { vault.secret(account).totp(account) }
        } catch (e: Exception) {
            message = e.message
        }
    }

    fun copyCode() = viewModelScope.launch {
        val account = account ?: return@launch
        try {
            val code = withUnlock("Copy the ${account.issuer} code") { vault.secret(account).totp(account).code() } ?: return@launch
            val clipboard = getApplication<Application>().getSystemService(ClipboardManager::class.java)
            clipboard.setPrimaryClip(ClipData.newPlainText("GateLink code", code))
            message = "Code copied."
        } catch (e: Exception) {
            message = e.message
        }
    }

    // MARK: Connection

    /** Connect when idle, cancel while working, disconnect when connected. */
    fun primaryAction() = viewModelScope.launch {
        when (vpnState.value) {
            is VpnState.Idle, is VpnState.Failed -> connect()
            is VpnState.Disconnecting -> Unit
            else -> GateLinkVpnService.disconnect(getApplication())
        }
    }

    private suspend fun connect() {
        message = null
        GateLinkVpnService.resetIfIdle()
        var account = account ?: run { message = "Add a 2FA account first (+)."; return }
        val portal = gateway.trim()
        val login = username.trim()
        when {
            portal.isEmpty() -> { message = "Enter the portal."; return }
            !Network.isValidHost(portal) -> { message = "The portal must be a hostname or IPv4 address (letters, digits, dots and hyphens)."; return }
            login.isEmpty() -> { message = "Enter your VPN username."; return }
            !account.hasPassword -> { message = "Set your VPN password first."; return }
        }
        gateway = portal
        prefs.edit().putString("gateway", portal).apply()
        if (account.username != login) {
            account = account.copy(username = login)
            vault.update(account)
        }

        val secret = try {
            withUnlock("Connect to $portal") { vault.secret(account) }
        } catch (e: Exception) {
            GateLinkVpnService.reportFailure(e.message ?: "Could not read the account secret.")
            return
        } ?: run { GateLinkVpnService.reportFailure("Unlock cancelled. VPN not connected."); return }
        val password = secret.vpnPassword
        if (password.isNullOrEmpty()) {
            GateLinkVpnService.reportFailure("No VPN password is saved for ${account.username}. Set it and press Connect.")
            return
        }
        if (platform?.allowVpn() != true) {
            GateLinkVpnService.reportFailure("GateLink needs permission to set up a VPN connection.")
            return
        }
        val code = freshCode(secret.totp(account))
        GateLinkVpnService.connect(getApplication(), portal, account.username, password + code)
    }

    /** Never reuses a code: gateways usually reject a replayed OTP, so a retry
     *  within the same 30 seconds waits for the next one. */
    private suspend fun freshCode(totp: Totp): String {
        var now = System.currentTimeMillis() / 1000
        lastCounter?.let { last ->
            if (totp.counter(now) <= last) {
                message = "Waiting for the next code…"
                delay((totp.nextRollover(now) - now) * 1000 + 500)
                message = null
                now = System.currentTimeMillis() / 1000
            }
        }
        lastCounter = totp.counter(now)
        return totp.code(now)
    }

    /** Runs `block`; when the Keystore key needs a fresh unlock, prompts once and retries.
     *  Returns null if the user cancels. */
    private suspend fun <T> withUnlock(reason: String, block: () -> T): T? {
        val result = try {
            block()
        } catch (e: VaultLockedException) {
            if (platform?.unlock(reason) != true) return null
            block()
        }
        unlockedUntil = System.currentTimeMillis() + Vault.UNLOCK_SECONDS * 1000
        return result
    }

    val version: String = application.packageManager.getPackageInfo(application.packageName, 0).versionName ?: "dev"
}
