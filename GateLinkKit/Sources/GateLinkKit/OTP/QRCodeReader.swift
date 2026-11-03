import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads `otpauth://` QR codes from images with the Vision framework.
public enum QRCodeReader {
    /// All QR payloads found in the image.
    public static func payloads(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            throw GateLinkError("Could not scan the image: \(error.localizedDescription)")
        }
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    public static func otpAuthURI(in image: CGImage) throws -> OTPAuthURI {
        try otpAuthURI(inPayloads: payloads(in: image))
    }

    /// The 2FA setup code among QR payloads, e.g. from a live camera scan.
    public static func otpAuthURI(inPayloads found: [String]) throws -> OTPAuthURI {
        guard !found.isEmpty else {
            throw GateLinkError("No QR code found in the image.")
        }
        guard let payload = found.first(where: { $0.lowercased().hasPrefix("otpauth://") })
                ?? found.first(where: { $0.lowercased().hasPrefix("otpauth-migration://") })
        else {
            throw GateLinkError("The QR code is not a 2FA setup code (otpauth://).")
        }
        return try OTPAuthURI.parse(payload)
    }

    public static func otpAuthURI(inImageAt url: URL) throws -> OTPAuthURI {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw GateLinkError("Could not open \(url.lastPathComponent) as an image.")
        }
        return try otpAuthURI(in: image)
    }
}
