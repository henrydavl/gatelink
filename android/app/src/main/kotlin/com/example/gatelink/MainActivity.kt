package com.example.gatelink

import android.app.Activity
import android.net.VpnService
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.example.gatelink.ui.GateLinkScreen
import com.example.gatelink.ui.theme.GateLinkTheme
import kotlin.coroutines.resume
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine

class MainActivity : FragmentActivity(), Platform {
    private val model: MainViewModel by viewModels()
    private var vpnConsent: CompletableDeferred<Boolean>? = null
    private val vpnPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        vpnConsent?.complete(it.resultCode == Activity.RESULT_OK)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        model.platform = this
        setContent {
            GateLinkTheme { GateLinkScreen(model) }
        }
    }

    override fun onDestroy() {
        if (model.platform === this) model.platform = null
        super.onDestroy()
    }

    /** Fingerprint, face or the screen lock; unlocks the vault key for 60 s. */
    override suspend fun unlock(reason: String): Boolean = suspendCancellableCoroutine { continuation ->
        val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (continuation.isActive) continuation.resume(true)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (continuation.isActive) continuation.resume(false)
            }
        })
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("GateLink")
                .setSubtitle(reason)
                .setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
                .build(),
        )
        continuation.invokeOnCancellation { prompt.cancelAuthentication() }
    }

    /** Android's "Connection request" dialog, shown once. */
    override suspend fun allowVpn(): Boolean {
        val intent = VpnService.prepare(this) ?: return true
        val consent = CompletableDeferred<Boolean>()
        vpnConsent = consent
        vpnPermission.launch(intent)
        return consent.await()
    }
}
