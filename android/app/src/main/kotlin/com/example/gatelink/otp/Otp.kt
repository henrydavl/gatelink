package com.example.gatelink.otp

import java.net.URI
import java.net.URLDecoder
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** A failure with a message that is safe to show as is (never a secret). */
class GateLinkException(message: String) : Exception(message)

/** RFC 4648 Base32 for TOTP secrets; ignores case, spaces, hyphens and padding. */
object Base32 {
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    fun decode(input: String): ByteArray {
        val cleaned = input.uppercase().filter { it != ' ' && it != '-' }.trimEnd('=')
        if (cleaned.isEmpty()) throw GateLinkException("The secret key is empty.")
        val out = java.io.ByteArrayOutputStream()
        var buffer = 0
        var bits = 0
        for (c in cleaned) {
            val value = ALPHABET.indexOf(c)
            if (value < 0) throw GateLinkException("The secret key contains an invalid character: \"$c\".")
            buffer = (buffer shl 5) or value
            bits += 5
            if (bits >= 8) {
                bits -= 8
                out.write((buffer shr bits) and 0xFF)
            }
        }
        return out.toByteArray()
    }

    fun normalized(secret: String) = secret.uppercase().filter { it != ' ' && it != '-' }
}

enum class OtpAlgorithm(val hmac: String) { SHA1("HmacSHA1"), SHA256("HmacSHA256"), SHA512("HmacSHA512") }

/** Time-based one-time passwords (RFC 6238 on top of RFC 4226). Times are Unix seconds. */
class Totp(
    private val secret: ByteArray,
    val digits: Int = 6,
    val period: Int = 30,
    val algorithm: OtpAlgorithm = OtpAlgorithm.SHA1,
) {
    init {
        if (secret.isEmpty()) throw GateLinkException("The secret key is empty.")
        if (digits !in 6..8) throw GateLinkException("Codes must have 6 to 8 digits.")
        if (period <= 0) throw GateLinkException("The code period must be positive.")
    }

    fun counter(seconds: Long): Long = maxOf(0, seconds) / period

    fun code(seconds: Long = nowSeconds()): String = codeForCounter(counter(seconds))

    fun codeForCounter(counter: Long): String {
        val name = algorithm.hmac
        val mac = Mac.getInstance(name).apply { init(SecretKeySpec(secret, name)) }
        val hash = mac.doFinal(java.nio.ByteBuffer.allocate(8).putLong(counter).array())
        // Dynamic truncation, RFC 4226 section 5.3.
        val offset = hash.last().toInt() and 0x0F
        val binary = ((hash[offset].toInt() and 0x7F) shl 24) or
            ((hash[offset + 1].toInt() and 0xFF) shl 16) or
            ((hash[offset + 2].toInt() and 0xFF) shl 8) or
            (hash[offset + 3].toInt() and 0xFF)
        var modulus = 1
        repeat(digits) { modulus *= 10 }
        return (binary % modulus).toString().padStart(digits, '0')
    }

    /** Seconds until the code shown at `seconds` rolls over (1..period). */
    fun secondsRemaining(seconds: Long = nowSeconds()): Int = period - (maxOf(0, seconds) % period).toInt()

    /** The first second of the step after the one containing `seconds`. */
    fun nextRollover(seconds: Long): Long = (counter(seconds) + 1) * period

    companion object {
        fun nowSeconds() = System.currentTimeMillis() / 1000

        fun fromBase32(secret: String, digits: Int = 6, period: Int = 30, algorithm: OtpAlgorithm = OtpAlgorithm.SHA1) =
            Totp(Base32.decode(secret), digits, period, algorithm)
    }
}

/** An `otpauth://totp/...` URI: the payload of a 2FA QR code. */
data class OtpAuthUri(
    val secret: String,
    val issuer: String?,
    val account: String?,
    val digits: Int = 6,
    val period: Int = 30,
    val algorithm: OtpAlgorithm = OtpAlgorithm.SHA1,
) {
    companion object {
        fun parse(text: String): OtpAuthUri {
            val trimmed = text.trim()
            if (trimmed.isEmpty()) throw GateLinkException("The otpauth URI is empty.")
            if (trimmed.lowercase().startsWith("otpauth-migration://")) {
                throw GateLinkException("Google Authenticator export codes are not supported. Use the account's original setup QR code.")
            }
            // Some generators leave spaces in the label unencoded.
            val uri = runCatching { URI(trimmed.replace(" ", "%20")) }.getOrNull()
            if (uri?.scheme?.lowercase() != "otpauth") throw GateLinkException("Not an otpauth:// URI.")
            if (uri.host?.lowercase() != "totp") throw GateLinkException("Only time-based codes (otpauth://totp/...) are supported.")
            val query = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.associate {
                val (key, value) = (it.split('=', limit = 2) + "").take(2)
                URLDecoder.decode(key, "UTF-8").lowercase() to URLDecoder.decode(value, "UTF-8")
            }
            val rawSecret = query["secret"]?.takeIf { it.isNotEmpty() } ?: throw GateLinkException("The otpauth URI has no secret.")
            Base32.decode(rawSecret)

            // The label is "Issuer:account" or just "account".
            val label = uri.path.orEmpty().removePrefix("/")
            val colon = label.indexOf(':')
            val labelIssuer = if (colon > 0) label.substring(0, colon).trim() else null
            val account = if (colon > 0) label.substring(colon + 1).trim() else label
            val parsed = OtpAuthUri(
                secret = Base32.normalized(rawSecret),
                issuer = query["issuer"]?.takeIf { it.isNotEmpty() } ?: labelIssuer?.takeIf { it.isNotEmpty() },
                account = account.takeIf { it.isNotEmpty() },
                digits = query["digits"]?.toIntOrNull()?.takeIf { it > 0 } ?: 6,
                period = query["period"]?.toIntOrNull()?.takeIf { it > 0 } ?: 30,
                algorithm = OtpAlgorithm.entries.firstOrNull { it.name == query["algorithm"]?.uppercase() } ?: OtpAlgorithm.SHA1,
            )
            // Reject digits or periods the code generator cannot use now, not at connect time.
            parsed.totp()
            return parsed
        }
    }

    fun totp() = Totp.fromBase32(secret, digits, period, algorithm)
}
