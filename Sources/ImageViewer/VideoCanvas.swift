import AVKit
import SwiftUI

extension Notification.Name {
    /// Sent when Space is pressed while a video is open.
    static let toggleVideoPlayback = Notification.Name("toggleVideoPlayback")
}

/// Plays a video with the standard macOS controls. Starts playing when opened.
struct VideoCanvas: View {
    let item: MediaItem

    var body: some View {
        VideoPlayerView(url: item.url)
            .id(item.url)
            .background(Color.black)
    }
}

private struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        private weak var view: AVPlayerView?
        private var observer: NSObjectProtocol?

        func attach(to view: AVPlayerView) {
            self.view = view
            observer = NotificationCenter.default.addObserver(
                forName: .toggleVideoPlayback, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let player = self?.view?.player else { return }
                    if player.timeControlStatus == .playing {
                        player.pause()
                    } else {
                        // Start over when the video already ended.
                        if let item = player.currentItem, item.currentTime() >= item.duration {
                            player.seek(to: .zero)
                        }
                        player.play()
                    }
                }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
