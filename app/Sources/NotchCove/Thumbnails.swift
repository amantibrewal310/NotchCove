import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnails (real image/PDF/video previews) with an icon fallback.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = makeCache(NSImage.self)
    private let loaders = makeCache(ThumbnailLoader.self)

    private static func makeCache<T>(_: T.Type) -> NSCache<NSString, T> {
        let cache = NSCache<NSString, T>()
        cache.countLimit = 300
        return cache
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.path)#\(Int(size))" as NSString
    }

    func loader(for url: URL, size: CGFloat) -> ThumbnailLoader {
        let cacheKey = key(url, size)
        if let loader = loaders.object(forKey: cacheKey) { return loader }
        let loader = ThumbnailLoader(url: url, size: size)
        loaders.setObject(loader, forKey: cacheKey)
        return loader
    }

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    /// Best image available right now, without waiting.
    func image(for url: URL, size: CGFloat) -> NSImage {
        cached(url, size: size) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Generates a Quick Look thumbnail, falling back to `icon`.
    func thumbnail(for url: URL, size: CGFloat, icon: NSImage) async -> NSImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        let image = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage ?? icon
        cache.setObject(image, forKey: key(url, size))
        return image
    }
}

/// Publishes one thumbnail; shared per file and size so views don't refetch.
@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage

    init(url: URL, size: CGFloat) {
        if let hit = ThumbnailCache.shared.cached(url, size: size) {
            image = hit
            return
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        image = icon
        Task { @MainActor [weak self] in
            let thumb = await ThumbnailCache.shared.thumbnail(for: url, size: size, icon: icon)
            self?.image = thumb
        }
    }
}

/// Uses an ObservableObject rather than @State so it builds with the Command
/// Line Tools alone (the @State macro plugin ships only with Xcode).
struct ThumbnailView: View {
    @ObservedObject private var loader: ThumbnailLoader
    private let size: CGFloat

    init(url: URL, size: CGFloat) {
        self.size = size
        loader = ThumbnailCache.shared.loader(for: url, size: size)
    }

    var body: some View {
        Image(nsImage: loader.image)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}
