import AppKit
import CoreImage

/// A small, tileable monochrome noise image, generated once and cached. Used
/// as a faint grain overlay on glass surfaces — real frosted glass has fine
/// micro-texture, and a touch of grain kills the flat "digital gaussian blur"
/// look that reads as fake.
enum NoiseTexture {
    /// 160×160 so it tiles without an obvious repeat at panel scale.
    static let shared: NSImage = make(side: 160)

    private static func make(side: CGFloat) -> NSImage {
        let fallback = NSImage(size: NSSize(width: side, height: side))
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else {
            return fallback
        }
        // CIRandomGenerator is colored; flatten to grayscale grain and force
        // opaque alpha so the tile composites predictably.
        let mono = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let cropped = mono.cropped(to: rect)
        guard let cg = CIContext().createCGImage(cropped, from: rect) else {
            return fallback
        }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }
}
