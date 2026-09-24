import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnails (real image/PDF/video previews) with an icon fallback.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    private func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.path)#\(Int(size))" as NSString
    }

    private let loaders: NSCache<NSString, ThumbnailLoader> = {
        let cache = NSCache<NSString, ThumbnailLoader>()
        cache.countLimit = 300
        return cache
    }()

    func loader(for url: URL, size: CGFloat) -> ThumbnailLoader {
        let cacheKey = key(url, size)
        if let loader = loaders.object(forKey: cacheKey) { return loader }
        let loader = ThumbnailLoader(url: url, size: size)
        loaders.setObject(loader, forKey: cacheKey)
        return loader
    }

    /// Best image available right now, without waiting.
    func image(for url: URL, size: CGFloat) -> NSImage {
        cache.object(forKey: key(url, size)) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage {
        let cacheKey = key(url, size)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        let image: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = rep.nsImage
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}

/// Publishes one thumbnail; shared per file and size so views don't refetch.
@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage

    init(url: URL, size: CGFloat) {
        image = ThumbnailCache.shared.image(for: url, size: size)
        Task { @MainActor [weak self] in
            let thumb = await ThumbnailCache.shared.thumbnail(for: url, size: size)
            self?.image = thumb
        }
    }
}

/// Plain SwiftUI image (no embedded AppKit view, so scrolling stays cheap).
/// Uses an ObservableObject rather than @State so it builds with the Command
/// Line Tools alone (SwiftUI's @State macro plugin ships only with Xcode).
struct ThumbnailView: View {
    @ObservedObject private var loader: ThumbnailLoader
    private let size: CGFloat

    init(url: URL, size: CGFloat = 48) {
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
