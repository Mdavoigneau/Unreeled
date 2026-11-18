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
///
/// A picture is decoded at the size it's shown at, not at its file's: a photo in a message is a
/// few hundred points wide, and its file may be several times that each way. One copy is kept
/// per picture, the largest asked for so far; a view that needs it larger has it decoded again.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    /// A decoded picture, and whether it's as large as it gets (its file's size, or the
    /// screen's): then it does for any view.
    private final class Kept {
        let image: UIImage
        let isWhole: Bool

        init(_ image: UIImage, isWhole: Bool) {
            self.image = image
            self.isWhole = isWhole
        }

        /// Large enough to fill a box of this many pixels.
        func fills(_ box: CGSize?) -> Bool {
            guard !isWhole else { return true }
            guard let box, let pixels = image.cgImage else { return false }
            return CGFloat(pixels.width) >= box.width - 1 && CGFloat(pixels.height) >= box.height - 1
        }
    }

    private let memory = NSCache<NSString, Kept>()
    /// Pictures being read, and the box each is being read for (nil: whole).
    private var loading: [String: (box: CGSize?, task: Task<Decoded, Never>)] = [:]
    /// Pictures that didn't decode even freshly downloaded: not asked for again while the app runs.
    private var undecodable: Set<String> = []

    private init() {
        memory.totalCostLimit = 150 << 20
    }

    /// The picture as it is in memory, at whatever size it was last needed.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: ImageFiles.key(for: url) as NSString)?.image
    }

    /// The picture from memory, from the phone, or downloaded (and kept on the phone), large
    /// enough to fill a view of `size` points; whole, up to the screen's size, without one.
    func image(for url: URL, store: PictureStore = .pictures, fitting size: CGSize? = nil) async -> UIImage? {
        let key = ImageFiles.key(for: url)
        let screen = Self.screen
        let box = size.map { CGSize(width: $0.width * screen.scale, height: $0.height * screen.scale) }
        if let kept = memory.object(forKey: key as NSString), kept.fills(box) { return kept.image }
        // One already on its way that will be large enough.
        if let under = loading[key], under.box == nil || (box.map { wanted in
            under.box.map { $0.width >= wanted.width && $0.height >= wanted.height } ?? true
        } ?? false) {
            return await under.task.value.image
        }
        guard !undecodable.contains(key) else { return nil }

        let largest = screen.largest
        let task = Task.detached(priority: .userInitiated) {
            await Self.decoded(url, download: true, store: store, largest: largest, box: box)
        }
        loading[key] = (box, task)
        let decoded = await task.value
        if loading[key]?.task == task { loading[key] = nil }
        switch decoded {
        case .image(let image, let isWhole): keep(image, isWhole: isWhole, for: key)
        case .undecodable: undecodable.insert(key)
        case .missing: break
        }
        return decoded.image
    }

    /// Loads pictures ahead, one at a time: decoded into memory when they're about to show (to
    /// fill `size` points, or whole), otherwise only onto the phone.
    func prefetch(_ urls: [URL], decode: Bool, fitting size: CGSize? = nil) {
        let urls = urls.filter { cached($0) == nil && !undecodable.contains(ImageFiles.key(for: $0)) }
        guard !urls.isEmpty else { return }
        Task(priority: .utility) {
            for url in urls {
                if decode {
                    _ = await image(for: url, fitting: size)
                } else if !ImageFiles.shared.contains(url) {
                    _ = await ImageFiles.shared.data(for: url)
                }
            }
        }
    }

    /// Decodes into memory the pictures already on the phone, for a screen that may open next:
    /// to fill `size` points, or whole. Downloads nothing.
    func warm(_ urls: [URL], fitting size: CGSize? = nil) {
        var seen = Set<String>()
        let urls = urls.filter { url in
            let key = ImageFiles.key(for: url)
            return memory.object(forKey: key as NSString) == nil && loading[key] == nil && !undecodable.contains(key)
                && seen.insert(key).inserted
        }
        guard !urls.isEmpty else { return }
        let screen = Self.screen
        let box = size.map { CGSize(width: $0.width * screen.scale, height: $0.height * screen.scale) }
        Task(priority: .utility) {
            for url in urls {
                let key = ImageFiles.key(for: url)
                guard memory.object(forKey: key as NSString) == nil,
                      case .image(let image, let isWhole) = await Task.detached(priority: .utility, operation: {
                          await Self.decoded(url, download: false, store: .pictures, largest: screen.largest, box: box)
                      }).value,
                      memory.object(forKey: key as NSString) == nil
                else { continue }
                keep(image, isWhole: isWhole, for: key)
            }
        }
    }

    /// A picture already in hand for a link, such as the photo you just sent, now that Instagram
    /// has given it one: whatever shows that link has the picture at once. Not in place of one
    /// already there.
    func seed(_ image: UIImage, for url: URL) {
        let key = ImageFiles.key(for: url)
        if memory.object(forKey: key as NSString) == nil { keep(image, isWhole: true, for: key) }
    }

    func removeAll() {
        memory.removeAllObjects()
        undecodable = []
    }

    private func keep(_ image: UIImage, isWhole: Bool, for key: String) {
        // Not a smaller one over a larger one that came meanwhile.
        if let kept = memory.object(forKey: key as NSString), kept.isWhole || !isWhole,
           kept.image.size.width * kept.image.scale >= image.size.width * image.scale { return }
        let bytes = image.size.width * image.size.height * image.scale * image.scale * 4
        memory.setObject(Kept(image, isWhole: isWhole), forKey: key as NSString, cost: Int(bytes))
    }

    /// The screen's scale, and the longest side, in pixels, that pictures are decoded at: the
    /// screen's, as no view shows one larger. A picture's file can claim any size, and decoding
    /// it whole would take as much memory as it claims.
    private static var screen: (scale: CGFloat, largest: CGFloat) {
        let screen = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let pixels = screen?.nativeBounds.size ?? CGSize(width: 1320, height: 2868)
        return (screen?.scale ?? 3, max(pixels.width, pixels.height))
    }

    /// What became of a picture: decoded (whole, or only as large as asked), not to be had for
    /// now (not on the phone, no connection), or not a picture even freshly downloaded.
    private enum Decoded {
        case image(UIImage, isWhole: Bool)
        case missing
        case undecodable

        var image: UIImage? {
            guard case .image(let image, _) = self else { return nil }
            return image
        }
    }

    /// The picture's file, decoded for display. A file that doesn't decode is downloaded again,
    /// once; if that doesn't decode either, it isn't kept.
    private nonisolated static func decoded(
        _ url: URL, download: Bool, store: PictureStore, largest: CGFloat, box: CGSize?
    ) async -> Decoded {
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
        if let (image, isWhole) = image(from: bytes, largest: largest, box: box) { return .image(image, isWhole: isWhole) }
        remove()
        guard download, let fresh = await data(download: true) else { return .missing }
        if let (image, isWhole) = image(from: fresh, largest: largest, box: box) { return .image(image, isWhole: isWhole) }
        remove()
        return .undecodable
    }

    /// The picture in `data`, upright and ready to draw: large enough to fill `box` pixels, and
    /// at most `largest` pixels on its longer side. ImageIO reads it down to that size as it
    /// decodes, without first decoding it whole. Also whether that is the whole picture: as
    /// large as its file, or as `largest`.
    private nonisolated static func image(from data: Data, largest: CGFloat, box: CGSize?) -> (UIImage, isWhole: Bool)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var longest = largest
        var isWhole = true
        if let box, box.width > 0, box.height > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let wide = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, wide > 0,
           let tall = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, tall > 0 {
            // A picture stored on its side is as wide as its file is tall.
            let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) > 4
            let (width, height) = turned ? (tall, wide) : (wide, tall)
            let needed = (max(width, height) * max(box.width / width, box.height / height)).rounded(.up)
            if needed < min(max(width, height), largest) {
                longest = needed
                isWhole = false
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (UIImage(cgImage: image), isWhole)
    }
}

/// An image from Instagram's CDN that fills its frame, cropped, or fits in it. It's read at the
/// size it's laid out at.
struct RemoteImage: View {
    let url: URL?
    var placeholder = Color(.secondarySystemBackground)
    var contentMode = ContentMode.fill
    var store = PictureStore.pictures
    @State private var image: UIImage?
    /// The picture `image` is of, by what stays the same in its link.
    @State private var shown: String?
    /// The size it's laid out at, in steps: a frame that moves by a hair asks for nothing new.
    @State private var size = CGSize.zero

    init(
        _ url: URL?, placeholder: Color = Color(.secondarySystemBackground), contentMode: ContentMode = .fill,
        store: PictureStore = .pictures
    ) {
        self.url = url
        self.placeholder = placeholder
        self.contentMode = contentMode
        self.store = store
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0) })
        _shown = State(initialValue: url.map(ImageFiles.key(for:)))
    }

    /// What to load: a picture, at a size. A link that only changed its signature is the same
    /// picture, and loads nothing again.
    private struct Wanted: Equatable {
        let picture: String?
        let size: CGSize
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
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: (proxy.size.width / 16).rounded(.up) * 16, height: (proxy.size.height / 16).rounded(.up) * 16)
            } action: { size = $0 }
            .task(id: Wanted(picture: url.map(ImageFiles.key(for:)), size: size)) {
                guard let url else { return image = nil }
                let picture = ImageFiles.key(for: url)
                if shown != picture {
                    // Another picture: what's in memory of it at once, or the placeholder.
                    shown = picture
                    image = ImageCache.shared.cached(url)
                }
                guard size.width > 0, size.height > 0 else { return }
                // The same picture at another size keeps showing until the new one is ready.
                if let loaded = await ImageCache.shared.image(for: url, store: store, fitting: size) { image = loaded }
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
