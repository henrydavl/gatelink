import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import GateLinkKit

@Suite struct Base32Tests {
    @Test(arguments: [
        ("", ""), ("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"),
        ("foob", "MZXW6YQ"), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI"),
    ])
    func rfc4648Vectors(plain: String, encoded: String) throws {
        #expect(Base32.encode(Data(plain.utf8)) == encoded)
        if !encoded.isEmpty {
            #expect(try Base32.decode(encoded) == Data(plain.utf8))
        }
    }

    @Test func decodeIgnoresCaseSpacesHyphensAndPadding() throws {
        #expect(try Base32.decode("mzxw 6ytb-oi======") == Data("foobar".utf8))
    }

    @Test func rejectsInvalidCharacters() {
        #expect(throws: GateLinkError.self) { try Base32.decode("MZXW1") }
        #expect(throws: GateLinkError.self) { try Base32.decode("   ") }
    }
}

@Suite struct TOTPTests {
    // RFC 6238 appendix B, 8 digits.
    static let sha1Secret = Data("12345678901234567890".utf8)
    static let sha256Secret = Data("12345678901234567890123456789012".utf8)
    static let sha512Secret = Data(("1234567890" + "1234567890" + "1234567890" + "1234567890"
        + "1234567890" + "1234567890" + "1234").utf8)

    @Test(arguments: [
        (59.0, "94287082", "46119246", "90693936"),
        (1_111_111_109.0, "07081804", "68084774", "25091201"),
        (1_111_111_111.0, "14050471", "67062674", "99943326"),
        (1_234_567_890.0, "89005924", "91819424", "93441116"),
        (2_000_000_000.0, "69279037", "90698825", "38618901"),
        (20_000_000_000.0, "65353130", "77737706", "47863826"),
    ])
    func rfc6238Vectors(time: Double, sha1: String, sha256: String, sha512: String) throws {
        let date = Date(timeIntervalSince1970: time)
        #expect(try TOTP(secret: Self.sha1Secret, digits: 8).code(at: date) == sha1)
        #expect(try TOTP(secret: Self.sha256Secret, digits: 8, algorithm: .sha256).code(at: date) == sha256)
        #expect(try TOTP(secret: Self.sha512Secret, digits: 8, algorithm: .sha512).code(at: date) == sha512)
    }

    @Test func sixDigitCodeIsTheLastSixDigits() throws {
        let totp = try TOTP(secret: Self.sha1Secret)
        #expect(totp.code(at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func countdownAndRollover() throws {
        let totp = try TOTP(secret: Self.sha1Secret)
        let date = Date(timeIntervalSince1970: 65)
        #expect(totp.secondsRemaining(at: date) == 25)
        #expect(totp.nextRollover(after: date) == Date(timeIntervalSince1970: 90))
        #expect(totp.counter(at: date) == 2)
    }

    @Test func rejectsBadParameters() {
        #expect(throws: GateLinkError.self) { try TOTP(secret: Data()) }
        #expect(throws: GateLinkError.self) { try TOTP(secret: Self.sha1Secret, digits: 5) }
        #expect(throws: GateLinkError.self) { try TOTP(secret: Self.sha1Secret, period: 0) }
    }
}

@Suite struct OTPAuthURITests {
    @Test func parsesAllFields() throws {
        let uri = try OTPAuthURI.parse(
            "otpauth://totp/Example%20VPN:jane%40example.com?secret=jbsw y3dp&issuer=Example&digits=8&period=60&algorithm=sha256"
                .replacingOccurrences(of: " ", with: "%20")
        )
        #expect(uri.secret == "JBSWY3DP")
        #expect(uri.issuer == "Example")
        #expect(uri.account == "jane@example.com")
        #expect(uri.digits == 8)
        #expect(uri.period == 60)
        #expect(uri.algorithm == .sha256)
    }

    @Test func takesIssuerFromLabelAndAppliesDefaults() throws {
        let uri = try OTPAuthURI.parse("otpauth://totp/Corp:bob?secret=JBSWY3DPEHPK3PXP")
        #expect(uri.issuer == "Corp")
        #expect(uri.account == "bob")
        #expect(uri.digits == 6)
        #expect(uri.period == 30)
        #expect(uri.algorithm == .sha1)
    }

    @Test(arguments: [
        "https://example.com/?secret=JBSWY3DP",
        "otpauth://hotp/x?secret=JBSWY3DP&counter=1",
        "otpauth://totp/x",
        "otpauth://totp/x?secret=1111",
        "otpauth-migration://offline?data=abc",
        "",
    ])
    func rejectsUnsupportedInput(_ text: String) {
        #expect(throws: GateLinkError.self) { try OTPAuthURI.parse(text) }
    }
}

@Suite struct AccountDraftTests {
    @Test func manualSecretUsesIssuerAndUsername() throws {
        let draft = try AccountDraft.fromManualInput("jbsw y3dp", issuer: " Corp VPN ", username: "jane")
        #expect(draft.account.issuer == "Corp VPN")
        #expect(draft.account.username == "jane")
        #expect(draft.secret.otpSecret == "JBSWY3DP")
        #expect(draft.secret.vpnPassword == nil)
    }

    @Test func uriInputKeepsQRLabelButAllowsUsernameOverride() throws {
        let draft = try AccountDraft.fromManualInput(
            "otpauth://totp/Corp:jane@corp.example?secret=JBSWY3DP", issuer: nil, username: "jdoe"
        )
        #expect(draft.account.issuer == "Corp")
        #expect(draft.account.label == "jane@corp.example")
        #expect(draft.account.username == "jdoe")
    }

    @Test func usernameDefaultsToTheQRLabel() throws {
        let draft = AccountDraft(uri: try OTPAuthURI.parse("otpauth://totp/Corp:jane?secret=JBSWY3DP"))
        #expect(draft.account.username == "jane")
    }

    @Test func rejectsEmptyAndInvalidInput() {
        #expect(throws: GateLinkError.self) { try AccountDraft.fromManualInput(" ", issuer: nil, username: nil) }
        #expect(throws: GateLinkError.self) { try AccountDraft.fromManualInput("not base32!", issuer: nil, username: nil) }
    }
}

@Suite struct QRCodeReaderTests {
    @Test func roundTripsAnOtpAuthQRCode() throws {
        let payload = "otpauth://totp/Corp:jane?secret=JBSWY3DPEHPK3PXP&issuer=Corp"
        let uri = try QRCodeReader.otpAuthURI(in: try Self.qrImage(payload))
        #expect(uri.secret == "JBSWY3DPEHPK3PXP")
        #expect(uri.account == "jane")
    }

    @Test func rejectsANonOTPQRCode() throws {
        let image = try Self.qrImage("https://example.com")
        #expect(throws: GateLinkError.self) { try QRCodeReader.otpAuthURI(in: image) }
    }

    static func qrImage(_ text: String) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let output = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        // Vision needs a quiet zone around the code.
        let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -40, dy: -40)))
        return try #require(CIContext().createCGImage(padded, from: padded.extent))
    }
}
