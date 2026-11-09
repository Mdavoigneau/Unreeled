import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A photo or video from the library, ready to upload: a JPEG or an MP4 at a sensible size, with
/// what it looks like for showing it straight away.
struct PreparedMedia: Identifiable {
    let id = UUID()
    let isVideo: Bool
    /// JPEG for a photo, MP4 for a video.
    let data: Data
    /// The photo, or the video's first frame.
    let preview: UIImage
    /// The video's first frame as JPEG: a story video needs it as its cover.
    let coverJPEG: Data?
    let width: Int
    let height: Int
    let durationMs: Int

    var mimeType: String { isVideo ? "video/mp4" : "image/jpeg" }
}

enum MediaPreparation {
    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? { "Couldn't read that photo or video." }
    }

    static func prepare(_ item: PhotosPickerItem) async throws -> PreparedMedia {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw Failure.unreadable }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return try await prepareVideo(at: movie.url)
        }
        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            throw Failure.unreadable
        }
        return try preparePhoto(image)
    }

    /// Upright, at most 1920 pixels on its longer side, as a JPEG.
    static func preparePhoto(_ image: UIImage) throws -> PreparedMedia {
        let scaled = resized(image, longestSide: 1920)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { throw Failure.unreadable }
        return PreparedMedia(
            isVideo: false, data: jpeg, preview: scaled, coverJPEG: nil,
            width: Int(scaled.size.width), height: Int(scaled.size.height), durationMs: 0
        )
    }

    /// Re-encoded as an H.264 MP4 of at most 1280×720, the format Instagram takes everywhere.
    static func prepareVideo(at url: URL) async throws -> PreparedMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720)
        else { throw Failure.unreadable }
        let output = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: output, as: .mp4)
        let data = try Data(contentsOf: output)

        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = naturalSize.applying(transform)
        var width = abs(upright.width)
        var height = abs(upright.height)
        let factor = min(1, 1280 / max(width, height), 720 / max(1, min(width, height)))
        width = (width * factor).rounded()
        height = (height * factor).rounded()
        let duration = try await asset.load(.duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let (frame, _) = try await generator.image(at: .zero)
        let cover = UIImage(cgImage: frame)
        return PreparedMedia(
            isVideo: true, data: data, preview: cover, coverJPEG: cover.jpegData(compressionQuality: 0.85),
            width: Int(width), height: Int(height), durationMs: Int(duration.seconds * 1000)
        )
    }

    static func resized(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let factor = min(1, longestSide / max(longest, 1))
        let size = CGSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing applies the photo's orientation, so the result is upright.
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// A video from the library, copied to a file the app can read.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
