import AppKit
import SwiftUI

/// Shows one image: fitted to the window by default, zoomable and scrollable.
struct ImageCanvas: View {
    @EnvironmentObject private var library: MediaLibrary
    let item: MediaItem

    @State private var loaded: LoadedImage?
    @State private var failedURL: URL?
    @State private var pinchBase: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if failedURL == item.url {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text("이 파일을 열 수 없어요")
                        Text(item.name).foregroundStyle(.secondary)
                    }
                } else if let loaded {
                    let fit = Self.fitScale(for: loaded.pixelSize, in: geo.size)
                    let scale = library.zoom ?? fit
                    ScrollView([.horizontal, .vertical]) {
                        AnimatedImageView(image: loaded.image)
                            .frame(
                                width: max(loaded.pixelSize.width * scale, 1),
                                height: max(loaded.pixelSize.height * scale, 1)
                            )
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .scrollIndicators(library.zoom == nil ? .hidden : .automatic)
                    .onChange(of: fit, initial: true) { _, newFit in
                        library.fitScale = newFit
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if library.zoom == nil { library.zoomActualSize() } else { library.zoomToFit() }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? library.effectiveZoom
                        pinchBase = base
                        library.setZoom(base * value.magnification)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .task(id: item.url) { await load(item.url) }
    }

    private func load(_ url: URL) async {
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard !Task.isCancelled else { return }
        guard let data, let image = NSImage(data: data) else {
            failedURL = url
            return
        }
        failedURL = nil
        loaded = LoadedImage(url: url, image: image, pixelSize: Self.pixelSize(of: image))
    }

    /// Fits the image inside the window without enlarging small images.
    static func fitScale(for imageSize: CGSize, in area: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(area.width / imageSize.width, area.height / imageSize.height, 1)
    }

    /// Real pixel dimensions. NSImage.size can be smaller or larger when the file has a DPI set.
    static func pixelSize(of image: NSImage) -> CGSize {
        let widest = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        if let rep = widest, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }
}

struct LoadedImage {
    let url: URL
    let image: NSImage
    let pixelSize: CGSize
}

/// NSImageView plays animated GIFs on its own, which SwiftUI's Image does not.
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        view.isEditable = false
        view.allowsCutCopyPaste = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
