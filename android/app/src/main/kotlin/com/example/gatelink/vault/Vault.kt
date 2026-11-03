package com.example.gatelink.vault

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import com.example.gatelink.otp.GateLinkException
import com.example.gatelink.otp.OtpAlgorithm
import com.example.gatelink.otp.OtpAuthUri
import com.example.gatelink.otp.Base32
import com.example.gatelink.otp.Totp
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject

/** A saved VPN account. Not secret; stored as plain JSON so the list loads without an unlock. */
data class Account(
    val id: String = UUID.randomUUID().toString(),
    val issuer: String,
    val label: String,
    val username: String,
    val digits: Int = 6,
    val period: Int = 30,
    val algorithm: OtpAlgorithm = OtpAlgorithm.SHA1,
    val hasPassword: Boolean = false,
)

/** The protected part of an account. */
data class AccountSecret(val otpSecret: String, val vpnPassword: String? = null) {
    fun totp(account: Account) = Totp.fromBase32(otpSecret, account.digits, account.period, account.algorithm)
}

/** A new account from a QR code or manual input, not yet saved. */
data class AccountDraft(val account: Account, val secret: AccountSecret) {
    companion object {
        fun fromUri(uri: OtpAuthUri, username: String? = null): AccountDraft {
            val label = uri.account.orEmpty()
            return AccountDraft(
                Account(
                    issuer = uri.issuer ?: "VPN", label = label,
                    username = username?.trim()?.takeIf { it.isNotEmpty() } ?: label,
                    digits = uri.digits, period = uri.period, algorithm = uri.algorithm,
                ),
                AccountSecret(uri.secret),
            )
        }

        /** Accepts either an `otpauth://` URI or a raw Base32 secret. */
        fun fromManualInput(text: String, issuer: String?, username: String?): AccountDraft {
            val input = text.trim()
            if (input.isEmpty()) throw GateLinkException("Enter an otpauth:// URI or a secret key.")
            val name = issuer?.trim()?.takeIf { it.isNotEmpty() }
            if (input.lowercase().startsWith("otpauth")) {
                val draft = fromUri(OtpAuthUri.parse(input), username)
                return if (name != null) draft.copy(account = draft.account.copy(issuer = name)) else draft
            }
            Base32.decode(input)
            val user = username?.trim().orEmpty()
            return AccountDraft(Account(issuer = name ?: "VPN", label = user, username = user), AccountSecret(Base32.normalized(input)))
        }
    }
}

/** Reading a secret needs a fingerprint or screen-lock check first. */
class VaultLockedException : Exception("The vault is locked.")

/**
 * Accounts in `accounts.json`, secrets AES-GCM encrypted with an Android
 * Keystore key that works for 60 s after the user unlocks (fingerprint or
 * screen lock), the same window as the Mac and iPhone apps.
 */
class Vault(private val dir: File) {
    private val _accounts = MutableStateFlow<List<Account>>(emptyList())
    val accounts: StateFlow<List<Account>> = _accounts

    private val accountsFile get() = File(dir, "accounts.json")
    private fun secretFile(id: String) = File(File(dir, "secrets").apply { mkdirs() }, id)

    fun load() {
        val file = accountsFile
        if (!file.exists()) return
        try {
            val array = JSONArray(file.readText())
            _accounts.value = (0 until array.length()).map { array.getJSONObject(it).toAccount() }
        } catch (e: Exception) {
            throw GateLinkException("The saved account list is unreadable: ${e.message}")
        }
    }

    fun accountForUsername(username: String, preferring: String?) = accountForUsername(accounts.value, username, preferring)

    fun add(draft: AccountDraft) {
        writeSecret(draft.account.id, draft.secret)
        val account = draft.account.copy(hasPassword = !draft.secret.vpnPassword.isNullOrEmpty())
        persist(accounts.value.filter { it.id != account.id } + account)
    }

    fun update(account: Account) {
        persist(accounts.value.map { if (it.id == account.id) account else it })
    }

    fun secret(account: Account): AccountSecret {
        val file = secretFile(account.id)
        if (!file.exists()) throw GateLinkException("The secret for ${account.issuer} is missing. Delete the account and add it again.")
        val bytes = file.readBytes()
        val cipher = cipher(Cipher.DECRYPT_MODE, bytes.copyOfRange(0, 12))
        val json = try {
            JSONObject(String(cipher.doFinal(bytes, 12, bytes.size - 12)))
        } catch (e: Exception) {
            throw GateLinkException("The saved account secret is unreadable. Delete the account and add it again.")
        }
        return AccountSecret(json.getString("otpSecret"), json.optString("vpnPassword").takeIf { it.isNotEmpty() })
    }

    fun setPassword(account: Account, password: String) {
        writeSecret(account.id, secret(account).copy(vpnPassword = password))
        update((accounts.value.firstOrNull { it.id == account.id } ?: account).copy(hasPassword = password.isNotEmpty()))
    }

    fun delete(account: Account) {
        secretFile(account.id).delete()
        persist(accounts.value.filter { it.id != account.id })
    }

    private fun writeSecret(id: String, secret: AccountSecret) {
        val cipher = cipher(Cipher.ENCRYPT_MODE, null)
        val json = JSONObject().put("otpSecret", secret.otpSecret).put("vpnPassword", secret.vpnPassword ?: "")
        val file = secretFile(id)
        val temp = File(file.parentFile, "$id.tmp")
        temp.writeBytes(cipher.iv + cipher.doFinal(json.toString().toByteArray()))
        if (!temp.renameTo(file)) throw GateLinkException("Could not save the account secret.")
    }

    private fun persist(updated: List<Account>) {
        val temp = File(dir, "accounts.json.tmp")
        temp.writeText(JSONArray(updated.map { it.toJson() }).toString(2))
        if (!temp.renameTo(accountsFile)) throw GateLinkException("Could not save the account list.")
        _accounts.value = updated
    }

    private fun cipher(mode: Int, iv: ByteArray?): Cipher = try {
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            if (iv == null) init(mode, key()) else init(mode, key(), GCMParameterSpec(128, iv))
        }
    } catch (e: UserNotAuthenticatedException) {
        throw VaultLockedException()
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(UNLOCK_SECONDS, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
            .build()
        return try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                init(spec)
                generateKey()
            }
        } catch (e: Exception) {
            throw GateLinkException("Set a screen lock (PIN, pattern or password) first; GateLink protects your secrets with it.")
        }
    }

    companion object {
        const val UNLOCK_SECONDS = 60
        private const val KEY_ALIAS = "gatelink-vault"

        /** The account whose username (or OTP label) is `username`, ignoring case. Accounts
         *  can share a username; then `preferring` wins if it is one of them. */
        fun accountForUsername(accounts: List<Account>, username: String, preferring: String?): Account? {
            val typed = username.trim()
            if (typed.isEmpty()) return null
            val byUsername = accounts.filter { it.username.equals(typed, ignoreCase = true) }
            val matches = byUsername.ifEmpty { accounts.filter { it.label.equals(typed, ignoreCase = true) } }
            return matches.firstOrNull { it.id == preferring } ?: matches.firstOrNull()
        }
    }
}

private fun Account.toJson() = JSONObject()
    .put("id", id).put("issuer", issuer).put("label", label).put("username", username)
    .put("digits", digits).put("period", period).put("algorithm", algorithm.name).put("hasPassword", hasPassword)

private fun JSONObject.toAccount() = Account(
    id = getString("id"), issuer = getString("issuer"), label = optString("label"), username = optString("username"),
    digits = optInt("digits", 6), period = optInt("period", 30),
    algorithm = OtpAlgorithm.valueOf(optString("algorithm", "SHA1")), hasPassword = optBoolean("hasPassword"),
)
