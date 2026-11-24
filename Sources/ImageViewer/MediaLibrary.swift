import AppKit
import Foundation

/// A run of files shown as one section of the thumbnail grid.
struct ItemSection: Identifiable, Sendable {
    let id: String
    let title: String
    let range: Range<Int>
}

enum ViewMode {
    case grid
    case single
}

enum BrowseMode: Hashable {
    /// One folder at a time: its subfolders as folder tiles, then its own files. Nothing below is read.
    case folder
    /// Every file in the selected folders and all of their subfolders.
    case all
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, date, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "이름"
        case .date: "수정한 날짜"
        case .size: "크기"
        }
    }
}

/// A folder in the sidebar. Its subfolders are read only when the row is shown.
@MainActor
final class FolderNode: ObservableObject, Identifiable {
    let url: URL
    let isRoot: Bool
    /// nil until read.
    @Published private(set) var children: [FolderNode]?
    private var isLoading = false

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isRoot: Bool) {
        self.url = url
        self.isRoot = isRoot
    }

    func loadChildren() async {
        guard children == nil, !isLoading else { return }
        isLoading = true
        let url = url
        let folders = await Task.detached(priority: .utility) { FileLister.subfolders(of: url) }.value
        children = folders.map { FolderNode(url: $0, isRoot: false) }
        isLoading = false
    }
}

/// The app's state: opened folders, what is shown, the selected file, sorting and zoom.
@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var rootFolders: [URL] = []
    @Published private(set) var rootNodes: [FolderNode] = []

    @Published var browseMode: BrowseMode = .folder {
        didSet { if browseMode != oldValue { browseModeChanged() } }
    }

    /// Folder shown in folder mode; nil shows the opened folders themselves.
    @Published private(set) var currentFolder: URL?
    /// Folder tiles shown in folder mode.
    @Published private(set) var subfolders: [URL] = []

    /// Files shown, sorted. The single view moves through these.
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var sections: [ItemSection] = []
    @Published private(set) var isLoading = false

    /// Folders highlighted in the sidebar. In "all" mode, these are the folders gathered (empty = all).
    @Published private(set) var selectedFolders: Set<URL> = []

    @Published var sortKey: SortKey = .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyKey)
            rebuild(keepingCurrent: true)
        }
    }

    @Published var sortAscending = true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: Self.sortAscendingKey)
            rebuild(keepingCurrent: true)
        }
    }

    @Published var viewMode: ViewMode = .grid

    @Published var currentIndex: Int = 0 {
        didSet { if currentIndex != oldValue { zoom = nil } }
    }

    /// nil means "fit to window"; otherwise 1.0 is actual pixel size.
    @Published var zoom: CGFloat?
    /// Scale that fits the current image in the window. Kept up to date by the view.
    @Published var fitScale: CGFloat = 1
    /// Number of thumbnail columns, kept up to date by the grid so ↑/↓ can move by rows.
    var gridColumns: Int = 1

    /// Files as read, before sorting.
    private var rawItems: [MediaItem] = []
    private var loadTask: Task<Void, Never>?
    private var previewCache: [URL: FolderPreview] = [:]

    private static let savedFoldersKey = "savedFolders"
    private static let sortKeyKey = "sortKey"
    private static let sortAscendingKey = "sortAscending"

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.sortKeyKey), let key = SortKey(rawValue: raw) {
            sortKey = key
        }
        if defaults.object(forKey: Self.sortAscendingKey) != nil {
            sortAscending = defaults.bool(forKey: Self.sortAscendingKey)
        }
        setRoots(Self.restoreSavedFolders())
    }

    var current: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var effectiveZoom: CGFloat { zoom ?? fitScale }

    var canGoUp: Bool { browseMode == .folder && currentFolder != nil }

    // MARK: Opened folders

    func chooseFolders() {
        guard let urls = pickFolders(prompt: "열기") else { return }
        setRoots(urls)
    }

    func addFolders() {
        guard let urls = pickFolders(prompt: "추가") else { return }
        add(folders: urls)
    }

    func add(folders: [URL]) {
        setRoots(rootFolders + folders)
    }

    func removeRoot(_ url: URL) {
        removeRoots([url])
    }

    func removeRoots(_ urls: Set<URL>) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        setRoots(rootFolders.filter { !paths.contains($0.standardizedFileURL.path) })
    }

    func closeAllFolders() {
        setRoots([])
    }

    /// Opened folders among the sidebar selection (only those can be removed from the list).
    var selectedRoots: Set<URL> {
        Set(selectedFolders.filter { rootFolders.contains($0) })
    }

    private func pickFolders(prompt: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        panel.message = "볼 폴더를 고르세요. ⌘를 누른 채 클릭하면 여러 개를 고를 수 있어요."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    private func setRoots(_ folders: [URL]) {
        var unique: [URL] = []
        for folder in folders.map(FileLister.normalized) where !unique.contains(folder) {
            unique.append(folder)
        }
        rootFolders = unique
        saveFolders(unique)

        let existing = Dictionary(uniqueKeysWithValues: rootNodes.map { ($0.url, $0) })
        rootNodes = unique.map { existing[$0] ?? FolderNode(url: $0, isRoot: true) }

        // Forget a folder or selection that is no longer under an opened folder.
        if let folder = currentFolder, !isUnderRoot(folder) { currentFolder = nil }
        selectedFolders = selectedFolders.filter(isUnderRoot)
        previewCache = [:]
        refresh()
    }

    private func isUnderRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return rootFolders.contains { FileLister.isSameOrInside(path, $0.standardizedFileURL.path) }
    }

    /// The opened folder that contains this folder (the deepest one, if they nest).
    private func root(for folder: URL) -> URL {
        let path = folder.standardizedFileURL.path
        return rootFolders
            .filter { FileLister.isSameOrInside(path, $0.standardizedFileURL.path) }
            .max { $0.path.count < $1.path.count } ?? folder
    }

    /// Saved as bookmarks, so they still open after being renamed or moved.
    private func saveFolders(_ folders: [URL]) {
        let bookmarks = folders.compactMap { try? $0.bookmarkData() }
        UserDefaults.standard.set(bookmarks, forKey: Self.savedFoldersKey)
    }

    private static func restoreSavedFolders() -> [URL] {
        guard let bookmarks = UserDefaults.standard.array(forKey: savedFoldersKey) as? [Data] else { return [] }
        return bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return url
        }
    }

    // MARK: Sidebar and folder navigation

    /// A click on a sidebar folder. ⌘-click adds or removes it from the selection;
    /// selecting more than one folder gathers all of their files.
    func sidebarClick(_ url: URL, toggle: Bool) {
        if toggle {
            if selectedFolders.contains(url) { selectedFolders.remove(url) } else { selectedFolders.insert(url) }
        } else {
            selectedFolders = [url]
        }

        if selectedFolders.count > 1, browseMode == .folder {
            browseMode = .all   // its didSet reloads
        } else if browseMode == .folder {
            currentFolder = selectedFolders.first
            refresh()
        } else {
            refresh()
        }
    }

    /// Clears the sidebar selection: the opened folders (folder mode) or everything (all mode).
    func showEverything() {
        selectedFolders = []
        currentFolder = nil
        refresh()
    }

    /// Opens a folder tile.
    func enter(_ folder: URL) {
        browseMode = .folder
        currentFolder = folder
        selectedFolders = [folder]
        refresh()
    }

    func goUp() {
        guard browseMode == .folder, let folder = currentFolder else { return }
        if rootFolders.contains(folder) {
            currentFolder = nil
            selectedFolders = []
        } else {
            let parent = FileLister.normalized(folder.deletingLastPathComponent())
            currentFolder = parent
            selectedFolders = [parent]
        }
        refresh()
    }

    private func browseModeChanged() {
        if browseMode == .folder {
            if selectedFolders.count == 1 {
                currentFolder = selectedFolders.first
            } else {
                selectedFolders = currentFolder.map { [$0] } ?? []
            }
        }
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        viewMode = .grid
        switch browseMode {
        case .folder: loadFolder()
        case .all: loadAll()
        }
    }

    /// Reads just the one folder being looked at.
    private func loadFolder() {
        guard let folder = currentFolder else {
            subfolders = rootFolders
            rawItems = []
            rebuild(keepingCurrent: false)
            isLoading = false
            return
        }
        let root = root(for: folder)
        isLoading = true
        loadTask = Task {
            let (folders, files) = await Task.detached(priority: .userInitiated) {
                FileLister.list(folder, root: root)
            }.value
            guard !Task.isCancelled else { return }
            subfolders = folders
            rawItems = files
            rebuild(keepingCurrent: false)
            isLoading = false
        }
    }

    /// Reads the selected folders and everything below them, showing files as they are found.
    private func loadAll() {
        subfolders = []
        rawItems = []
        rebuild(keepingCurrent: false)

        let scope = (selectedFolders.isEmpty ? rootFolders : Array(selectedFolders))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let targets = scope.map { ScanTarget(folder: $0, root: root(for: $0)) }
        isLoading = !targets.isEmpty
        guard !targets.isEmpty else { return }

        loadTask = Task {
            var lastRebuild = Date.distantPast
            for await batch in FileLister.scan(targets) {
                guard !Task.isCancelled else { return }
                rawItems += batch
                // Re-sorting a big list costs time, so do it less often as the list grows.
                let interval = rawItems.count < 5000 ? 0.3 : 1.5
                if Date().timeIntervalSince(lastRebuild) >= interval {
                    rebuild(keepingCurrent: true)
                    lastRebuild = Date()
                }
            }
            guard !Task.isCancelled else { return }
            rebuild(keepingCurrent: true)
            isLoading = false
        }
    }

    /// Folder tile preview, read once per folder.
    func preview(for folder: URL) async -> FolderPreview {
        if let cached = previewCache[folder] { return cached }
        let preview = await Task.detached(priority: .utility) { FileLister.preview(of: folder) }.value
        previewCache[folder] = preview
        return preview
    }

    // MARK: Sorting and sections

    private var groupsByFolder: Bool { browseMode == .all && sortKey == .name }

    private func rebuild(keepingCurrent: Bool) {
        let keepID = keepingCurrent ? current?.id : nil
        items = Self.sorted(rawItems, key: sortKey, ascending: sortAscending, groupByFolder: groupsByFolder)
        sections = makeSections()
        if let keepID, let index = items.firstIndex(where: { $0.id == keepID }) {
            if index != currentIndex { currentIndex = index }
        } else {
            currentIndex = 0
        }
        if items.isEmpty { viewMode = .grid }
    }

    nonisolated static func sorted(
        _ items: [MediaItem], key: SortKey, ascending: Bool, groupByFolder: Bool
    ) -> [MediaItem] {
        items.sorted { a, b in
            if groupByFolder {
                let order = a.folder.path.localizedStandardCompare(b.folder.path)
                if order != .orderedSame { return order == .orderedAscending }
            }
            let order: ComparisonResult
            switch key {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .date:
                order = a.modified == b.modified ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            case .size:
                order = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func makeSections() -> [ItemSection] {
        guard !items.isEmpty else { return [] }
        guard groupsByFolder else {
            return [ItemSection(id: "all", title: browseMode == .folder ? "사진" : "전체", range: 0..<items.count)]
        }
        var sections: [ItemSection] = []
        var start = 0
        while start < items.count {
            let folder = items[start].folder
            var end = start + 1
            while end < items.count, items[end].folder == folder { end += 1 }
            sections.append(ItemSection(
                id: folder.path,
                title: FileLister.displayPath(of: folder, under: items[start].root),
                range: start..<end
            ))
            start = end
        }
        return sections
    }

    /// Where the grid is, for the path bar in folder mode.
    var locationTitle: String {
        guard let folder = currentFolder else { return "열린 폴더" }
        return FileLister.displayPath(of: folder, under: root(for: folder))
    }

    // MARK: Navigation

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    func open(_ index: Int) {
        select(index)
        if current != nil { viewMode = .single }
    }

    func next() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex + 1) % items.count
    }

    func previous() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex - 1 + items.count) % items.count
    }

    func moveBy(_ offset: Int) {
        guard !items.isEmpty else { return }
        currentIndex = min(max(currentIndex + offset, 0), items.count - 1)
    }

    func first() { select(0) }
    func last() { select(items.count - 1) }

    func toggleViewMode() {
        guard current != nil else { return }
        viewMode = viewMode == .grid ? .single : .grid
    }

    // MARK: Zoom

    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 32

    func setZoom(_ value: CGFloat) {
        zoom = min(max(value, Self.minZoom), Self.maxZoom)
    }

    func zoomIn() { setZoom(effectiveZoom * 1.25) }
    func zoomOut() { setZoom(effectiveZoom / 1.25) }
    func zoomToFit() { zoom = nil }
    func zoomActualSize() { zoom = 1 }

    func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    func revealInFinder(_ url: URL? = nil) {
        guard let url = url ?? current?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Keyboard

    /// Keys without a menu shortcut. Returns true when the key was used.
    /// Arrow keys always move between files, even while the sidebar has focus.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])

        // ⌘↑ goes to the parent folder.
        if mods == .command, event.keyCode == 126, viewMode == .grid, canGoUp {
            goUp()
            return true
        }
        guard mods.isEmpty else { return false }

        let inGrid = viewMode == .grid
        switch event.keyCode {
        case 124: next()                                        // right arrow
        case 123: previous()                                    // left arrow
        case 125: inGrid ? moveBy(gridColumns) : next()         // down arrow
        case 126: inGrid ? moveBy(-gridColumns) : previous()    // up arrow
        case 49: next()                                         // space
        case 121: next()                                        // page down
        case 116: previous()                                    // page up
        case 115: first()                                       // home
        case 119: last()                                        // end
        case 36, 76:                                            // return, enter
            toggleViewMode()
        case 51:                                                // delete (backspace)
            if inGrid, canGoUp { goUp() } else { return false }
        case 53:                                                // escape
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else if viewMode == .single {
                viewMode = .grid
            } else {
                return false
            }
        default:
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "f" {
                toggleFullScreen()
                return true
            }
            guard !inGrid else { return false }
            switch key {
            case "+", "=": zoomIn()
            case "-": zoomOut()
            case "0": zoomToFit()
            case "1": zoomActualSize()
            default: return false
            }
        }
        return true
    }
}
