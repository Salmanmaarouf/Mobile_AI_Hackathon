import SwiftUI
import CoreGraphics
import CoreImage
import ImageIO

struct Memory: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let date: String
    let gradient: [Color]

    /// Base name of the bundled photograph this memory opens into, without an
    /// extension (e.g. "mamas_birthday" for `Memories/mamas_birthday.jpg`).
    ///
    /// Deliberately a loose bundled file rather than an asset-catalog entry: the
    /// spatial pipeline needs the ORIGINAL file bytes, not a decoded raster.
    /// Apple's `Spatial3DImage` reads the file itself, and the field of view is
    /// recovered from the EXIF focal-length tag — which the asset catalog
    /// strips. Losing it drops the reconstruction back to a 63° guess, and that
    /// is the difference between the memory feeling like the photograph and
    /// feeling like a poster of it.
    ///
    /// `nil` means the memory is still artwork-only: it shows in the library,
    /// but there is nothing to step into yet.
    let photoResource: String?
}

// MARK: - Loading the photograph

extension Memory {

    /// A decoded frame plus the bytes it was decoded from. The pipeline wants
    /// both — the raster to work on, the bytes to read EXIF from.
    struct Photo {
        let image: CGImage
        let data: Data
    }

    var hasPhoto: Bool { photoResource != nil }

    /// Reads the bundled photograph. Returns `nil` when the memory has no photo
    /// attached, or when the file is missing or undecodable.
    func loadPhoto() -> Photo? {
        guard let photoResource else { return nil }

        // Try the common still-photo extensions rather than pinning one, so a
        // HEIC straight off a phone works the same as an exported JPEG.
        let candidates = ["jpg", "jpeg", "heic", "HEIC", "png"]
        let url = candidates.lazy
            .compactMap { Bundle.main.url(forResource: photoResource, withExtension: $0) }
            .first

        guard let url,
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        return Photo(image: Self.upright(decoded, from: source), data: data)
    }

    /// Applies the EXIF orientation tag to the decoded frame.
    ///
    /// `CGImageSourceCreateImageAtIndex` hands back the raw pixel buffer and
    /// ignores the orientation tag entirely, so a photo taken with the phone
    /// turned arrives on its side. Everything downstream is geometry — the
    /// depth mesh places each pixel along a view ray — so a sideways frame
    /// produces a sideways room rather than a cosmetic glitch.
    ///
    /// Left alone when the tag is absent or already upright, which is the
    /// common case and costs nothing.
    private static func upright(_ image: CGImage, from source: CGImageSource) -> CGImage {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let raw = properties[kCGImagePropertyOrientation] as? UInt32,
            raw != 1
        else { return image }

        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(raw))
        guard let rotated = CIContext().createCGImage(oriented, from: oriented.extent) else {
            return image
        }
        return rotated
    }
}

extension Memory {

    /// Trimmed to the memories that actually have a photograph behind them.
    ///
    /// A library card that opens into nothing is worse than no card: this is an
    /// app for someone who may not be sure whether they mis-remembered or the
    /// machine broke. Add an entry here as you add a file to `Anchor/Memories/`,
    /// naming `photoResource` after the file (without its extension).
    static let sample: [Memory] = [
        Memory(
            title: "The Studio",
            date: "Aug 30, 2026",
            gradient: [Color(red: 0.98, green: 0.62, blue: 0.42), Color(red: 0.87, green: 0.42, blue: 0.55)],
            photoResource: "the_studio"
        ),
        Memory(
            title: "The Courtyard",
            date: "Aug 30, 2026",
            gradient: [Color(red: 0.55, green: 0.45, blue: 0.72), Color(red: 0.35, green: 0.32, blue: 0.55)],
            photoResource: "the_courtyard"
        ),
        Memory(
            title: "The Garden",
            date: "Aug 30, 2026",
            gradient: [Color(red: 0.45, green: 0.68, blue: 0.86), Color(red: 0.62, green: 0.82, blue: 0.85)],
            photoResource: "the_garden"
        )
    ]
}
