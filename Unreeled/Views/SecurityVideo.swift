import AVKit
import SwiftUI

/// The short video on how Unreeled keeps an account private: the one on unreeled.app/security,
/// played from the copies the app carries (Unreeled/Video), so it starts at once and asks no
/// server for anything.
///
/// Held upright, the phone shows the video's tall shape, which takes the whole screen but for
/// three things: the cross that closes it, the button for captions, and under it the link to the
/// page that says the same in writing. On its side, it shows the wide shape, the website's, with
/// the two buttons beside it. A swipe down closes it too, as for a video from a conversation.
struct SecurityVideo: View {
    /// The part to start at, by its name in security-chapters.json. The beginning without one.
    var chapter: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var player = AVPlayer()
    @State private var drag: CGFloat = 0
    /// On from the start when the phone is set to show captions (Accessibility › Subtitles &
    /// Captioning).
    @State private var showsCaptions = UIAccessibility.isClosedCaptioningEnabled

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if isSideways {
                // The player is exactly the picture's size, so its own buttons stay inside the
                // picture, and it leaves a margin on each side for the cross and the captions.
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .padding(.horizontal, 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: drag)
                buttons
            } else {
                VStack(spacing: 0) {
                    buttons
                    VideoPlayer(player: player)
                        .aspectRatio(3 / 5, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: drag)
                    Link(destination: chapter == nil ? Links.security : Links.notifications) {
                        HStack(spacing: 6) {
                            Text("Learn more on unreeled.app")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .light))
                        }
                        .font(Theme.font(15))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .onChange(of: showsCaptions) { showCaptions() }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { drag = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height > 120 {
                        dismiss()
                    } else {
                        withAnimation(.snappy) { drag = 0 }
                    }
                }
        )
        // Again whenever the phone is turned: the other shape takes over.
        .task(id: isSideways) { await show() }
        .onDisappear { player.pause() }
        .statusBarHidden()
    }

    private var isSideways: Bool { verticalSizeClass == .compact }

    /// The cross on the left, the button for captions on the right.
    private var buttons: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            Spacer()
            Button { showsCaptions.toggle() } label: {
                Image(systemName: showsCaptions ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Captions")
            .accessibilityValue(showsCaptions ? "On" : "Off")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    /// Plays the shape that fits how the phone is held. The two have the same sound and the same
    /// length, so when the phone is turned the other carries on from the same moment.
    private func show() async {
        let turned = player.currentItem != nil
        let moment = player.currentTime()
        let wasPlaying = player.timeControlStatus != .paused
        // Turned again meanwhile: the later turn has its own call.
        guard let item = await Self.item(isSideways ? "security" : "security-tall"), !Task.isCancelled else { return }
        player.replaceCurrentItem(with: item)
        showCaptions()
        if turned {
            await player.seek(to: moment, toleranceBefore: .zero, toleranceAfter: .zero)
        } else if let chapter, let start = Self.start(of: chapter) {
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if !turned || wasPlaying { player.play() }
        // A track switched off before the video is ready can come back on with it: say it again then.
        for await status in item.publisher(for: \.status).values where status == .readyToPlay {
            showCaptions()
            break
        }
    }

    /// Shows the captions or not, as the button says. They're a track of the video like its picture
    /// and its sound, drawn by the system in the style the phone is set to.
    private func showCaptions() {
        for track in player.currentItem?.tracks ?? [] where track.assetTrack?.mediaType == .text {
            track.isEnabled = showsCaptions
        }
    }

    /// One shape of the video, by its file's name, with the captions. They're a file of their own,
    /// the same for both shapes and for the website, so video and captions are put together here.
    private static func item(_ name: String) async -> AVPlayerItem? {
        guard let videoURL = Bundle.main.url(forResource: name, withExtension: "mp4") else { return nil }
        let video = AVURLAsset(url: videoURL)
        guard let captionsURL = Bundle.main.url(forResource: "security", withExtension: "vtt") else {
            return AVPlayerItem(asset: video)
        }
        let captions = AVURLAsset(url: captionsURL)
        let together = AVMutableComposition()
        do {
            let length = try await video.load(.duration)
            for kind in [AVMediaType.video, .audio] {
                guard let from = try await video.loadTracks(withMediaType: kind).first,
                      let track = together.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: from, at: .zero)
                if kind == .audio { track.extendedLanguageTag = "en" }
            }
            if let from = try await captions.loadTracks(withMediaType: .text).first,
               let track = together.addMutableTrack(withMediaType: .text, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let captioned = min(length, try await captions.load(.duration))
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: captioned), of: from, at: .zero)
                track.extendedLanguageTag = "en"
            }
            return AVPlayerItem(asset: together)
        } catch {
            // Without captions rather than not at all.
            return AVPlayerItem(asset: video)
        }
    }

    /// Where a part of the video begins, in seconds: website/video/build.py writes the list.
    private static func start(of chapter: String) -> Double? {
        struct Chapter: Decodable {
            let title: String
            let start: Double
        }
        guard let url = Bundle.main.url(forResource: "security-chapters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let chapters = try? JSONDecoder().decode([Chapter].self, from: data)
        else { return nil }
        return chapters.first { $0.title == chapter }?.start
    }
}
