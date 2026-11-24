import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: MediaLibrary
    @State private var keyMonitor: Any?
    @AppStorage("thumbnailSize") private var thumbSize: Double = 160

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .navigationTitle(title)
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

    private var title: String {
        if library.viewMode == .single, let item = library.current { return item.name }
        switch library.browseMode {
        case .folder:
            return library.currentFolder?.lastPathComponent ?? "이미지 뷰어"
        case .all:
            return "전체 모아보기"
        case .picked:
            return "선택 모아보기"
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if library.viewMode == .grid, library.browseMode == .folder, !library.rootFolders.isEmpty {
                PathBar()
                Divider()
            }
            if library.viewMode == .grid, library.hasPicks {
                PickBar()
                Divider()
            }

            if library.viewMode == .single, let item = library.current {
                ImageCanvas(item: item)
            } else if library.rootFolders.isEmpty {
                EmptyStateView()
            } else if library.items.isEmpty, library.subfolders.isEmpty {
                VStack(spacing: 8) {
                    if library.isLoading {
                        ProgressView()
                        Text("폴더를 읽는 중…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("이 폴더에는 볼 수 있는 파일이 없어요")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThumbnailGrid(thumbSize: CGFloat(thumbSize))
            }

            if !library.rootFolders.isEmpty {
                StatusBar()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { library.chooseFolders() } label: {
                Label("폴더 열기", systemImage: "folder.badge.plus")
            }
            .help("폴더 열기 (⌘O)")

            Picker("보는 방식", selection: $library.browseMode) {
                Text("폴더별").tag(BrowseMode.folder)
                Text("전체 모아보기").tag(BrowseMode.all)
                if library.hasPicks || library.browseMode == .picked {
                    Text("선택 모아보기").tag(BrowseMode.picked)
                }
            }
            .pickerStyle(.segmented)
            .help("폴더별: 한 폴더씩 들어가며 보기 / 전체 모아보기: 하위 폴더의 사진까지 한꺼번에 보기")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("폴더 정렬") {
                    Picker("폴더 정렬 기준", selection: $library.sort.folderKey) {
                        ForEach(FolderSortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Picker("폴더 순서", selection: $library.sort.folderAscending) {
                        Text("오름차순").tag(true)
                        Text("내림차순").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("폴더 안 사진 정렬") {
                    Picker("사진 정렬 기준", selection: $library.sort.fileKey) {
                        ForEach(SortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Picker("사진 순서", selection: $library.sort.fileAscending) {
                        Text("오름차순").tag(true)
                        Text("내림차순").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            } label: {
                Label("정렬", systemImage: "arrow.up.arrow.down")
            }
            .help(sortHelp)

            if library.viewMode == .grid {
                Slider(value: $thumbSize, in: 80...280) {
                    Text("썸네일 크기")
                } minimumValueLabel: {
                    Image(systemName: "photo").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "photo").imageScale(.large)
                }
                .frame(width: 140)
                .help("썸네일 크기")
            } else {
                Button { library.viewMode = .grid } label: {
                    Label("썸네일로", systemImage: "square.grid.2x2")
                }
                .help("썸네일로 돌아가기 (Esc)")

                Button { library.zoomOut() } label: {
                    Label("축소", systemImage: "minus.magnifyingglass")
                }
                .help("축소 (-)")

                Button { library.zoomToFit() } label: {
                    Label("화면에 맞추기", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .help("화면에 맞추기 (0)")

                Button { library.zoomIn() } label: {
                    Label("확대", systemImage: "plus.magnifyingglass")
                }
                .help("확대 (+)")
            }

            Button { library.toggleFullScreen() } label: {
                Label("전체화면", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("전체화면 (F)")
        }
    }

    private var sortHelp: String {
        let s = library.sort
        let folderOrder = s.folderAscending ? "오름차순" : "내림차순"
        let fileOrder = s.fileAscending ? "오름차순" : "내림차순"
        return "폴더: \(s.folderKey.title) \(folderOrder) / 사진: \(s.fileKey.title) \(fileOrder)"
    }

    /// Dropping folders (or files) onto the window adds their folders.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }

        Task { @MainActor in
            var folders: [URL] = []
            for provider in fileProviders {
                guard let url = await loadURL(from: provider) else { continue }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                folders.append(isDir.boolValue ? url : url.deletingLastPathComponent())
            }
            if !folders.isEmpty { library.add(folders: folders) }
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

/// Where you are in folder mode, with a button to go up.
private struct PathBar: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        HStack(spacing: 8) {
            Button { library.goUp() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!library.canGoUp)
            .help("상위 폴더로 (⌘↑ 또는 Delete)")

            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(library.locationTitle)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// What is ⌘-clicked, with buttons to view it all together or clear it.
private struct PickBar: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(summary)
            Spacer()
            if library.browseMode != .picked {
                Button("선택 모아보기") { library.openPicked() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("고른 사진과 고른 폴더 안의 모든 사진을 모아서 봐요")
            }
            Button("선택 해제") { library.clearPicks() }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private var summary: String {
        var parts: [String] = []
        if !library.pickedFolders.isEmpty { parts.append("폴더 \(library.pickedFolders.count)개") }
        if !library.pickedFiles.isEmpty { parts.append("사진 \(library.pickedFiles.count)개") }
        return parts.joined(separator: ", ") + " 선택됨  ·  ⌘ 클릭으로 더 고를 수 있어요"
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("폴더를 열어 주세요")
                .font(.title2)
            Text("한 번 연 폴더는 기억해 두었다가 다음에도 바로 보여줘요.\n폴더 여러 개를 한 번에 고르거나, 창에 끌어다 놓아도 돼요.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 12) {
            if let item = library.current {
                Text("\(library.currentIndex + 1) / \(library.items.count)")
                    .monospacedDigit()
                Text(item.displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) { library.revealInFinder() }
                    .help("두 번 누르면 Finder에서 보여줘요")
            } else {
                Text("사진 없음").foregroundStyle(.secondary)
            }
            Spacer()
            if library.isLoading, library.browseMode != .folder {
                ProgressView().controlSize(.small)
                Text("찾는 중… \(library.items.count)개")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if library.viewMode == .single {
                Text(library.zoom == nil ? "맞춤 \(percent(library.fitScale))" : percent(library.effectiveZoom))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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
