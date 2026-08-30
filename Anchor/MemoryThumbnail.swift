import SwiftUI
import CoreGraphics
import ImageIO

/// Decoded, downsampled previews of the memory photographs, cached for the
/// app's lifetime.
///
/// The photographs are 24-megapixel HEICs. Decoding one at full size costs
/// nearly 100 MB and a noticeable pause, and the carousel would do it for every
/// card on every scroll. `CGImageSourceCreateThumbnailAtIndex` decodes STRAIGHT
/// to the size asked for — the full raster is never allocated — which is the
/// difference between a smooth carousel and a stuttering one.
@MainActor
@Observable
final class MemoryThumbnailStore {

    static let shared = MemoryThumbnailStore()

    /// Long edge of the cached preview, in pixels. Comfortably above the
    /// largest place one is drawn (the orb, a few hundred points on a retina
    /// display) and far below the source.
    private static let maxPixelSize = 900

    private var cache: [String: Image] = [:]
    private var inFlight: Set<String> = []

    private init() {}

    /// The cached preview, if it has been loaded. Nil means "not yet" — call
    /// `load(_:)` and read again when it publishes.
    func thumbnail(for memory: Memory) -> Image? {
        guard let key = memory.photoResource else { return nil }
        return cache[key]
    }

    /// Decodes the memory's photograph at preview size. Safe to call repeatedly:
    /// already-cached and already-loading resources return immediately.
    func load(_ memory: Memory) async {
        guard let key = memory.photoResource,
              cache[key] == nil,
              inFlight.contains(key) == false
        else { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let maxPixel = Self.maxPixelSize
        // Off the main actor: even a downsampling decode is real work, and this
        // runs while the home screen is live.
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodeThumbnail(resource: key, maxPixel: maxPixel)
        }.value

        if let decoded {
            cache[key] = Image(decoded, scale: 1, label: Text(memory.title))
        }
    }

    /// - Returns: the photograph decoded to at most `maxPixel` on its long edge,
    ///   with its EXIF orientation already applied.
    private nonisolated static func decodeThumbnail(resource: String, maxPixel: Int) -> CGImage? {
        let candidates = ["heic", "HEIC", "jpg", "jpeg", "png"]
        guard let url = candidates.lazy
            .compactMap({ Bundle.main.url(forResource: resource, withExtension: $0) })
            .first,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // Applies the orientation tag during decode, so a photo taken with
            // the phone turned does not arrive on its side.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - View

/// The memory's photograph, filling the space it is given.
///
/// Falls back to the memory's gradient — while the decode is in flight, and
/// permanently for a memory with no photograph attached. The gradient is a
/// deliberate stand-in rather than a spinner: the library should look composed
/// at all times, not like it is waiting for something.
struct MemoryThumbnail: View {
    let memory: Memory

    @State private var store = MemoryThumbnailStore.shared

    var body: some View {
        ZStack {
            LinearGradient(
                colors: memory.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image = store.thumbnail(for: memory) {
                // Drawn as an overlay on a flexible `Color.clear` rather than
                // placed directly, so the photograph fills the space without
                // DRIVING it. `scaledToFill` on a placed image reports a layout
                // size larger than the container, which grows whatever holds it
                // — the card's rounded clip then rounds a rectangle bigger than
                // the photo, and the photo's own square corners show inside it.
                Color.clear
                    .overlay {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: store.thumbnail(for: memory) == nil)
        .task(id: memory.id) {
            await store.load(memory)
        }
    }
}
