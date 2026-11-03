import Foundation

/// RFC 4648 Base32, used for TOTP shared secrets.
///
/// Decoding is case-insensitive and ignores spaces, hyphens and trailing
/// padding, which authenticator setup keys often contain.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static let values: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            map[character] = UInt8(index)
        }
        return map
    }()

    public static func decode(_ input: String) throws -> Data {
        var cleaned = input.uppercased().filter { $0 != " " && $0 != "-" }
        while cleaned.hasSuffix("=") { cleaned.removeLast() }
        guard !cleaned.isEmpty else {
            throw GateLinkError("The secret key is empty.")
        }

        var output = Data(capacity: cleaned.count * 5 / 8)
        var buffer: UInt32 = 0
        var bitsLeft = 0
        for character in cleaned {
            guard let value = values[character] else {
                throw GateLinkError("The secret key contains an invalid character: \"\(character)\".")
            }
            buffer = (buffer << 5) | UInt32(value)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                output.append(UInt8((buffer >> UInt32(bitsLeft)) & 0xFF))
            }
        }
        return output
    }

    public static func encode(_ data: Data) -> String {
        var result = ""
        var buffer: UInt32 = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                result.append(alphabet[Int((buffer >> UInt32(bitsLeft)) & 0x1F)])
            }
        }
        if bitsLeft > 0 {
            result.append(alphabet[Int((buffer << UInt32(5 - bitsLeft)) & 0x1F)])
        }
        return result
    }
}
