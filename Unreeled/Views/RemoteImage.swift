import ImageIO
import SwiftUI
import UIKit

/// Where a picture's file is kept: with the other pictures, or with stories, which go after a day.
enum PictureStore {
    case pictures, stories
}

/// Decoded images kept in memory, on top of the files kept on the phone (ImageFiles, StoryFiles),
/// so scrolling back is instant. Both go by what stays the same in a picture's link (see
/// `ImageFiles.key`), so a refreshed screen, whose links are all new, still finds its pictures.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private var loading: [String: Task<Decoded, Never>] = [:]
    /// Pictures that didn't decode even freshly downloaded: not asked for again while the app runs.
    private var undecodable: Set<String> = []

    private init() {
        memory.totalCostLimit = 150 << 20
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: ImageFiles.key(for: url) as NSString)
    }

    /// The picture from memory, from the phone, or downloaded (and kept on the phone).
    func image(for url: URL, store: PictureStore = .pictures) async -> UIImage? {
        let key = ImageFiles.key(for: url)
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = loading[key] { return await task.value.image }
        guard !undecodable.contains(key) else { return nil }

        let largest = Self.largest
        let task = Task.detached(priority: .userInitiated) { await Self.decoded(url, download: true, store: store, largest: largest) }
        loading[key] = task
        let decoded = await task.value
        loading[key] = nil
        switch decoded {
        case .image(let image): keep(image, for: key)
        case .undecodable: undecodable.insert(key)
        case .missing: break
        }
        return decoded.image
    }

    /// Loads pictures ahead, one at a time: decoded into memory when they're about to show,
    /// otherwise only onto the phone.
    func prefetch(_ urls: [URL], decode: Bool) {
        let urls = urls.filter { cached($0) == nil && !undecodable.contains(ImageFiles.key(for: $0)) }
        guard !urls.isEmpty else { return }
        Task(priority: .utility) {
            for url in urls {
                if decode {
                    _ = await image(for: url)
                } else if !ImageFiles.shared.contains(url) {
                    _ = await ImageFiles.shared.data(for: url)
                }
            }
        }
    }

    /// Decodes into memory the pictures already on the phone, for a screen that may open next.
    /// Downloads nothing.
    func warm(_ urls: [URL]) {
        var seen = Set<String>()
        let urls = urls.filter { url in
            let key = ImageFiles.key(for: url)
            return memory.object(forKey: key as NSString) == nil && loading[key] == nil && !undecodable.contains(key)
                && seen.insert(key).inserted
        }
        guard !urls.isEmpty else { return }
        let largest = Self.largest
        Task(priority: .utility) {
            for url in urls {
                let key = ImageFiles.key(for: url)
                guard memory.object(forKey: key as NSString) == nil,
                      let image = await Task.detached(priority: .utility, operation: {
                          await Self.decoded(url, download: false, store: .pictures, largest: largest)
                      }).value.image
                else { continue }
                keep(image, for: key)
            }
        }
    }

    func removeAll() {
        memory.removeAllObjects()
        undecodable = []
    }

    private func keep(_ image: UIImage, for key: String) {
        let bytes = image.size.width * image.size.height * image.scale * image.scale * 4
        memory.setObject(image, forKey: key as NSString, cost: Int(bytes))
    }

    /// The longest side, in pixels, that pictures are decoded at: the screen's, as no view shows
    /// one larger. A picture's file can claim any size, and decoding it whole would take as much
    /// memory as it claims.
    private static var largest: CGFloat {
        let screen = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let pixels = screen?.nativeBounds.size ?? CGSize(width: 1320, height: 2868)
        return max(pixels.width, pixels.height)
    }

    /// What became of a picture: decoded, not to be had for now (not on the phone, no
    /// connection), or not a picture even freshly downloaded.
    private enum Decoded {
        case image(UIImage)
        case missing
        case undecodable

        var image: UIImage? {
            guard case .image(let image) = self else { return nil }
            return image
        }
    }

    /// The picture's file, decoded for display. A file that doesn't decode is downloaded again,
    /// once; if that doesn't decode either, it isn't kept.
    private nonisolated static func decoded(_ url: URL, download: Bool, store: PictureStore, largest: CGFloat) async -> Decoded {
        func data(download: Bool) async -> Data? {
            switch store {
            case .pictures: await ImageFiles.shared.data(for: url, download: download)
            case .stories: await StoryFiles.shared.data(for: url, download: download)
            }
        }
        func remove() {
            switch store {
            case .pictures: ImageFiles.shared.remove(url)
            case .stories: StoryFiles.shared.remove(url)
            }
        }
        guard let bytes = await data(download: download) else { return .missing }
        if let image = image(from: bytes, largest: largest) { return .image(image) }
        remove()
        guard download, let fresh = await data(download: true) else { return .missing }
        if let image = image(from: fresh, largest: largest) { return .image(image) }
        remove()
        return .undecodable
    }

    /// The picture in `data`, upright and ready to draw, at most `largest` pixels on its longer
    /// side: ImageIO reads it down to that size as it decodes, without first decoding it whole.
    private nonisolated static func image(from data: Data, largest: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: largest,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// An image from Instagram's CDN that fills its frame, cropped, or fits in it.
struct RemoteImage: View {
    let url: URL?
    var placeholder = Color(.secondarySystemBackground)
    var contentMode = ContentMode.fill
    var store = PictureStore.pictures
    @State private var image: UIImage?

    init(
        _ url: URL?, placeholder: Color = Color(.secondarySystemBackground), contentMode: ContentMode = .fill,
        store: PictureStore = .pictures
    ) {
        self.url = url
        self.placeholder = placeholder
        self.contentMode = contentMode
        self.store = store
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0) })
    }

    var body: some View {
        Rectangle()
            .fill(placeholder)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return image = nil }
                if let cached = ImageCache.shared.cached(url) { return image = cached }
                image = await ImageCache.shared.image(for: url, store: store)
            }
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        RemoteImage(url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
    }
}
