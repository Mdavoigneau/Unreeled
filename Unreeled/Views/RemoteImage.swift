import SwiftUI
import UIKit

/// Decoded images kept in memory, on top of URLCache's copies on disk, so scrolling back is instant.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private var loading: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        memory.totalCostLimit = 200 << 20
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        if let task = loading[url] { return await task.value }

        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return await UIImage(data: data)?.byPreparingForDisplay()
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image {
            let bytes = image.size.width * image.size.height * image.scale * image.scale * 4
            memory.setObject(image, forKey: url as NSURL, cost: Int(bytes))
        }
        return image
    }

    /// Loads pictures ahead, one at a time: decoded into memory when they're about to show,
    /// otherwise only onto disk.
    func prefetch(_ urls: [URL], decode: Bool) {
        let urls = urls.filter { cached($0) == nil }
        guard !urls.isEmpty else { return }
        Task(priority: .utility) {
            for url in urls {
                if decode {
                    _ = await image(for: url)
                } else {
                    _ = try? await URLSession.shared.data(from: url)
                }
            }
        }
    }

    func removeAll() {
        memory.removeAllObjects()
    }
}

/// An image from Instagram's CDN that fills its frame, cropped.
struct RemoteImage: View {
    let url: URL?
    var placeholder = Color(.secondarySystemBackground)
    @State private var image: UIImage?

    init(_ url: URL?, placeholder: Color = Color(.secondarySystemBackground)) {
        self.url = url
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0) })
    }

    var body: some View {
        Rectangle()
            .fill(placeholder)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return image = nil }
                if let cached = ImageCache.shared.cached(url) { return image = cached }
                image = await ImageCache.shared.image(for: url)
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
