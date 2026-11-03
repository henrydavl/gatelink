package com.example.gatelink.otp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** The same vectors as GateLinkKit's OTPTests (RFC 4648, RFC 6238 appendix B). */
class OtpTest {
    private val sha1 = "12345678901234567890".toByteArray()
    private val sha256 = "12345678901234567890123456789012".toByteArray()
    private val sha512 = "1234567890123456789012345678901234567890123456789012345678901234".toByteArray()

    @Test fun base32Vectors() {
        listOf("f" to "MY", "fo" to "MZXQ", "foo" to "MZXW6", "foob" to "MZXW6YQ", "fooba" to "MZXW6YTB", "foobar" to "MZXW6YTBOI")
            .forEach { (plain, encoded) -> assertArrayEquals(plain.toByteArray(), Base32.decode(encoded)) }
        assertArrayEquals("foobar".toByteArray(), Base32.decode("mzxw 6ytb-oi======"))
        assertThrows(GateLinkException::class.java) { Base32.decode("MZXW1") }
        assertThrows(GateLinkException::class.java) { Base32.decode("   ") }
    }

    @Test fun rfc6238Vectors() {
        listOf(
            Triple(59L, "94287082", "46119246") to "90693936",
            Triple(1_111_111_109L, "07081804", "68084774") to "25091201",
            Triple(1_111_111_111L, "14050471", "67062674") to "99943326",
            Triple(1_234_567_890L, "89005924", "91819424") to "93441116",
            Triple(2_000_000_000L, "69279037", "90698825") to "38618901",
            Triple(20_000_000_000L, "65353130", "77737706") to "47863826",
        ).forEach { (row, expected512) ->
            val (time, expected1, expected256) = row
            assertEquals(expected1, Totp(sha1, digits = 8).code(time))
            assertEquals(expected256, Totp(sha256, digits = 8, algorithm = OtpAlgorithm.SHA256).code(time))
            assertEquals(expected512, Totp(sha512, digits = 8, algorithm = OtpAlgorithm.SHA512).code(time))
        }
        assertEquals("287082", Totp(sha1).code(59L))
    }

    @Test fun countdownAndRollover() {
        val totp = Totp(sha1)
        assertEquals(25, totp.secondsRemaining(65))
        assertEquals(90L, totp.nextRollover(65))
        assertEquals(2L, totp.counter(65))
    }

    @Test fun parsesAnOtpAuthUri() {
        val uri = OtpAuthUri.parse("otpauth://totp/Corp%20VPN:jane@example.com?secret=jbsw y3dp-ehpk3pxp&issuer=Corp&digits=8&period=60&algorithm=sha256")
        assertEquals(OtpAuthUri("JBSWY3DPEHPK3PXP", "Corp", "jane@example.com", 8, 60, OtpAlgorithm.SHA256), uri)
        val bare = OtpAuthUri.parse("otpauth://totp/Corp:jane?secret=JBSWY3DPEHPK3PXP")
        assertEquals("Corp", bare.issuer)
        assertEquals(6, bare.digits)
    }

    @Test fun rejectsUnsupportedInput() {
        listOf(
            "https://example.com/?secret=JBSWY3DP",
            "otpauth://hotp/x?secret=JBSWY3DP&counter=1",
            "otpauth://totp/x",
            "otpauth://totp/x?secret=1111",
            "otpauth://totp/x?secret=JBSWY3DP&digits=10",
            "otpauth-migration://offline?data=abc",
            "",
        ).forEach { assertThrows(it, GateLinkException::class.java) { OtpAuthUri.parse(it) } }
    }
}
