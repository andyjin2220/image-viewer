import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: MediaLibrary
    @State private var keyMonitor: Any?
    @AppStorage("thumbnailSize") private var thumbSize: Double = 160
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeImmersive: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            detail
                .searchable(text: $library.filterText, placement: .toolbar, prompt: "파일 이름으로 찾기")
                .toolbar { toolbarContent }
                .toolbar(library.immersive ? .hidden : .visible, for: .windowToolbar)
        }
        .navigationTitle(title)
        .onChange(of: library.immersive) { _, immersive in
            if immersive {
                visibilityBeforeImmersive = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = visibilityBeforeImmersive
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            library.fullScreenChanged(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            library.fullScreenChanged(false)
        }
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
            if library.viewMode == .grid, library.isFiltering {
                FilterBar()
                Divider()
            }
            if library.viewMode == .grid, library.hasPicks {
                PickBar()
                Divider()
            }

            if library.viewMode == .single, let item = library.current {
                if item.kind == .video {
                    VideoCanvas(item: item)
                } else {
                    ImageCanvas(item: item)
                }
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
                        Text(library.isFiltering ? "필터에 맞는 파일이 없어요" : "이 폴더에는 볼 수 있는 파일이 없어요")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThumbnailGrid(thumbSize: CGFloat(thumbSize))
            }

            if !library.rootFolders.isEmpty, !library.immersive {
                StatusBar()
            }
        }
        .background(library.immersive ? Color.black : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if library.immersive, library.viewMode == .single {
                ImmersiveHUD()
            }
        }
        .onContinuousHover { phase in
            if library.immersive, case .active = phase {
                NotificationCenter.default.post(name: .immersiveMouseMoved, object: nil)
            }
        }
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
                ForEach(FileFilter.choices, id: \.ext) { choice in
                    Toggle(choice.ext.uppercased(), isOn: Binding(
                        get: { library.filterExtensions.contains(choice.ext) },
                        set: { _ in library.toggleFilterExtension(choice.ext) }
                    ))
                }
                Divider()
                Button("모든 형식 보기") { library.filterExtensions = [] }
                    .disabled(library.filterExtensions.isEmpty)
            } label: {
                Label(
                    "형식 필터",
                    systemImage: library.filterExtensions.isEmpty
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .help("확장자로 거르기 (여러 개 고를 수 있어요)")

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

                Button { library.toggleImmersive() } label: {
                    Label("이미지만 보기", systemImage: "rectangle.dashed")
                }
                .help("이미지만 크게 보기 (H 또는 Tab, 나가기는 Esc)")

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

            Menu {
                ForEach(MediaLibrary.slideshowIntervals, id: \.self) { seconds in
                    Toggle("\(Int(seconds))초마다", isOn: Binding(
                        get: { library.slideshowInterval == seconds },
                        set: { _ in library.slideshowInterval = seconds }
                    ))
                }
            } label: {
                Label("슬라이드쇼", systemImage: library.isSlideshowRunning ? "pause.circle" : "play.circle")
            } primaryAction: {
                library.toggleSlideshow()
            }
            .help("슬라이드쇼 (S): 누르면 시작/멈춤, 화살표로 넘기는 간격 선택 (지금 \(Int(library.slideshowInterval))초)")
            .disabled(library.current == nil)

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

/// In image-only mode: file name and position, shown when the mouse moves and hidden after 2 seconds,
/// together with the mouse pointer.
private struct ImmersiveHUD: View {
    @EnvironmentObject private var library: MediaLibrary
    @State private var isVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(false)
            .overlay(alignment: .bottom) {
                if isVisible, let item = library.current {
                    HStack(spacing: 12) {
                        Text("\(library.currentIndex + 1) / \(library.items.count)")
                            .monospacedDigit()
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if library.isSlideshowRunning {
                            Label("\(Int(library.slideshowInterval))초마다", systemImage: "play.fill")
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Text(library.isSlideshowRunning ? "S 멈춤 · Esc 나가기" : "Esc 나가기")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
                }
            }
            .onAppear { scheduleHide() }
            .onDisappear { hideTask?.cancel() }
            .onChange(of: library.currentIndex) { show() }
            .onReceive(NotificationCenter.default.publisher(for: .immersiveMouseMoved)) { _ in show() }
    }

    private func show() {
        withAnimation(.easeOut(duration: 0.15)) { isVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { isVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

extension Notification.Name {
    static let immersiveMouseMoved = Notification.Name("immersiveMouseMoved")
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

/// Shows the active filter, with buttons to gather matches from subfolders or clear it.
private struct FilterBar: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(summary)
                .lineLimit(1)
            Spacer()
            if library.browseMode == .folder {
                Button("하위 폴더까지 모아보기") { library.gatherFilteredFromHere() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("이 폴더와 모든 하위 폴더에서 필터에 맞는 파일만 모아서 봐요")
            }
            Button("필터 지우기") { library.clearFilter() }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private var summary: String {
        var parts: [String] = []
        let text = library.filter.trimmedText
        if !text.isEmpty { parts.append("이름에 \"\(text)\"") }
        if !library.filterExtensions.isEmpty {
            let exts = FileFilter.choices.map(\.ext).filter(library.filterExtensions.contains)
            parts.append(exts.map { $0.uppercased() }.joined(separator: ", "))
        }
        let found = library.isLoading ? "찾는 중" : "\(library.items.count)개"
        return "필터: " + parts.joined(separator: " · ") + "  →  " + found
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
            if library.viewMode == .single, library.current?.kind != .video {
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
