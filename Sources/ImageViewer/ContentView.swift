import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: MediaLibrary
    @State private var keyMonitor: Any?

    var body: some View {
        Group {
            if library.isScanning {
                ProgressView("폴더를 살펴보는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let item = library.current {
                VStack(spacing: 0) {
                    ImageCanvas(item: item)
                    StatusBar(item: item)
                }
            } else {
                EmptyStateView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(library.current?.name ?? "이미지 뷰어")
        .toolbar { toolbarContent }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { library.handleKey(event) } ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { library.chooseFolders() } label: {
                Label("폴더 열기", systemImage: "folder")
            }
            .help("폴더 열기 (⌘O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { library.previous() } label: {
                Label("이전", systemImage: "chevron.left")
            }
            .help("이전 파일 (←)")
            .disabled(library.items.isEmpty)

            Button { library.next() } label: {
                Label("다음", systemImage: "chevron.right")
            }
            .help("다음 파일 (→)")
            .disabled(library.items.isEmpty)

            Divider()

            Button { library.zoomOut() } label: {
                Label("축소", systemImage: "minus.magnifyingglass")
            }
            .help("축소 (-)")
            .disabled(library.current == nil)

            Button { library.zoomToFit() } label: {
                Label("화면에 맞추기", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .help("화면에 맞추기 (0)")
            .disabled(library.current == nil)

            Button { library.zoomIn() } label: {
                Label("확대", systemImage: "plus.magnifyingglass")
            }
            .help("확대 (+)")
            .disabled(library.current == nil)

            Button { library.toggleFullScreen() } label: {
                Label("전체화면", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("전체화면 (F)")
        }
    }

    /// Dropping folders (or files) onto the window opens them.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await loadURL(from: provider) { urls.append(url) }
            }
            let folders = urls.map { url -> URL in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue ? url : url.deletingLastPathComponent()
            }
            var unique: [URL] = []
            for folder in folders where !unique.contains(folder) { unique.append(folder) }
            if !unique.isEmpty { library.load(folders: unique) }
        }
        return true
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            if library.rootFolders.isEmpty {
                Text("폴더를 열어 주세요")
                    .font(.title2)
                Text("하위 폴더까지 모두 불러와요. 폴더 여러 개를 한 번에 고르거나,\n창에 폴더를 끌어다 놓아도 돼요.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("볼 수 있는 파일이 없어요")
                    .font(.title2)
                Text("고른 폴더 안에서 png, jpg, gif, psd 같은 파일을 찾지 못했어요.")
                    .foregroundStyle(.secondary)
            }
            Button("폴더 열기…") { library.chooseFolders() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var library: MediaLibrary
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Text("\(library.currentIndex + 1) / \(library.items.count)")
                .monospacedDigit()
            Text(item.displayPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) { library.revealInFinder() }
                .help("두 번 누르면 Finder에서 보여줘요")
            Spacer()
            Text(library.zoom == nil ? "맞춤 \(percent(library.fitScale))" : percent(library.effectiveZoom))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func percent(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
