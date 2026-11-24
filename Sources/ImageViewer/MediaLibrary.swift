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
    /// Only what was ⌘-clicked: those files, plus every file inside the ⌘-clicked folders.
    case picked
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

enum FolderSortKey: String, CaseIterable, Identifiable {
    case name, date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "이름"
        case .date: "수정한 날짜"
        }
    }
}

/// How to order things. Sent to a background task, so it is a plain value.
struct SortSettings: Sendable, Equatable {
    var folderKey: FolderSortKey
    var folderAscending: Bool
    var fileKey: SortKey
    var fileAscending: Bool
}

/// A folder in the sidebar. Its subfolders are read only when the row is shown.
@MainActor
final class FolderNode: ObservableObject, Identifiable {
    let url: URL
    let isRoot: Bool
    /// nil until read.
    @Published private(set) var children: [FolderNode]?
    private var isLoading = false

    nonisolated var id: URL { url }
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

/// The app's state: opened folders, what is shown, the selected file, ⌘-click picks, sorting and zoom.
@MainActor
final class MediaLibrary: ObservableObject {
    /// The grid shows this many more files each time you scroll near the end,
    /// so a folder with tens of thousands of files never builds them all at once.
    static let pageSize = 300

    @Published private(set) var rootFolders: [URL] = []
    @Published private(set) var rootNodes: [FolderNode] = []

    @Published var browseMode: BrowseMode = .folder {
        didSet { if browseMode != oldValue { browseModeChanged() } }
    }

    /// Folder shown in folder mode; nil shows the opened folders themselves.
    @Published private(set) var currentFolder: URL?
    /// Folder tiles shown in folder mode, sorted.
    @Published private(set) var subfolders: [URL] = []

    /// Files in the current view, sorted. The single view moves through all of these.
    @Published private(set) var items: [MediaItem] = []
    /// How many of `items` the grid shows so far.
    @Published private(set) var displayLimit = MediaLibrary.pageSize
    /// Sections covering the shown part of `items`.
    @Published private(set) var sections: [ItemSection] = []
    @Published private(set) var isLoading = false

    /// Folders highlighted in the sidebar. In "all" mode, these are the folders gathered (empty = all).
    @Published private(set) var selectedFolders: Set<URL> = []

    /// ⌘-clicked files and folders. They stay picked while you move between folders.
    @Published private(set) var pickedFiles: [URL: MediaItem] = [:]
    @Published private(set) var pickedFolders: Set<URL> = []

    @Published var sort: SortSettings {
        didSet {
            guard sort != oldValue else { return }
            saveSort()
            subfolders = Self.sortedFolders(rawSubfolders, sort)
            rebuild(keepingCurrent: true)
        }
    }

    @Published var viewMode: ViewMode = .grid {
        didSet { if viewMode == .grid { immersive = false } }
    }

    /// "Image only": hides the sidebar, toolbar and bars so the picture fills the window.
    /// Turned on automatically in full screen.
    @Published var immersive = false

    @Published var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue { zoom = nil }
            ensureDisplayed(currentIndex)
        }
    }

    /// nil means "fit to window"; otherwise 1.0 is actual pixel size.
    @Published var zoom: CGFloat?
    /// Scale that fits the current image in the window. Kept up to date by the view.
    @Published var fitScale: CGFloat = 1
    /// Number of thumbnail columns, kept up to date by the grid so ↑/↓ can move by rows.
    var gridColumns: Int = 1

    /// Files as read, before sorting.
    private var rawItems: [MediaItem] = []
    private var rawSubfolders: [FolderEntry] = []
    private var loadTask: Task<Void, Never>?
    private var arrangeGeneration = 0
    private var openSingleWhenReady = false
    private var previewCache: [URL: FolderPreview] = [:]

    private static let savedFoldersKey = "savedFolders"
    private static let sortKey = "sortSettings.v2"

    init() {
        sort = Self.loadSort()
        setRoots(Self.restoreSavedFolders())
    }

    var current: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var effectiveZoom: CGFloat { zoom ?? fitScale }

    var canGoUp: Bool { browseMode == .folder && currentFolder != nil }

    var hasPicks: Bool { !pickedFiles.isEmpty || !pickedFolders.isEmpty }

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

        // Forget places and picks that are no longer under an opened folder.
        if let folder = currentFolder, !isUnderRoot(folder) { currentFolder = nil }
        selectedFolders = selectedFolders.filter(isUnderRoot)
        pickedFolders = pickedFolders.filter(isUnderRoot)
        pickedFiles = pickedFiles.filter { isUnderRoot($0.key) }
        previewCache = [:]
        if browseMode == .picked, !hasPicks {
            browseMode = .folder   // its didSet reloads
            return
        }
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

    private func saveSort() {
        let values: [String: Any] = [
            "folderKey": sort.folderKey.rawValue,
            "folderAscending": sort.folderAscending,
            "fileKey": sort.fileKey.rawValue,
            "fileAscending": sort.fileAscending,
        ]
        UserDefaults.standard.set(values, forKey: Self.sortKey)
    }

    private static func loadSort() -> SortSettings {
        let values = UserDefaults.standard.dictionary(forKey: sortKey) ?? [:]
        return SortSettings(
            folderKey: (values["folderKey"] as? String).flatMap(FolderSortKey.init(rawValue:)) ?? .name,
            folderAscending: values["folderAscending"] as? Bool ?? true,
            fileKey: (values["fileKey"] as? String).flatMap(SortKey.init(rawValue:)) ?? .name,
            fileAscending: values["fileAscending"] as? Bool ?? true
        )
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

        if selectedFolders.count > 1 {
            if browseMode != .all { browseMode = .all } else { refresh() }
        } else if browseMode == .all {
            refresh()
        } else {
            currentFolder = selectedFolders.first
            if browseMode != .folder { browseMode = .folder } else { refresh() }
        }
    }

    /// Clears the sidebar selection: the opened folders (folder mode) or everything (all mode).
    func showEverything() {
        selectedFolders = []
        currentFolder = nil
        if browseMode == .picked { browseMode = .folder } else { refresh() }
    }

    /// Opens a folder tile.
    func enter(_ folder: URL) {
        currentFolder = folder
        selectedFolders = [folder]
        if browseMode != .folder { browseMode = .folder } else { refresh() }
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
        arrangeGeneration += 1
        viewMode = .grid
        displayLimit = Self.pageSize
        switch browseMode {
        case .folder:
            loadFolder()
        case .all:
            subfolders = []
            rawSubfolders = []
            let scope = selectedFolders.isEmpty ? rootFolders : Array(selectedFolders)
            gather(folders: scope, files: [])
        case .picked:
            subfolders = []
            rawSubfolders = []
            gather(folders: Array(pickedFolders), files: Array(pickedFiles.values))
        }
    }

    /// Reads just the one folder being looked at.
    private func loadFolder() {
        guard let folder = currentFolder else {
            rawSubfolders = rootFolders.map { FolderEntry(url: $0, modified: FileLister.modifiedDate(of: $0)) }
            subfolders = Self.sortedFolders(rawSubfolders, sort)
            rawItems = []
            isLoading = false
            rebuild(keepingCurrent: false)
            return
        }
        let root = root(for: folder)
        isLoading = true
        loadTask = Task {
            let (folders, files) = await Task.detached(priority: .userInitiated) {
                FileLister.list(folder, root: root)
            }.value
            guard !Task.isCancelled else { return }
            rawSubfolders = folders
            subfolders = Self.sortedFolders(folders, sort)
            rawItems = files
            isLoading = false
            rebuild(keepingCurrent: false)
        }
    }

    /// Reads folders and everything below them (plus some single files), showing files as they are found.
    /// While reading, new files are added at the end; they are sorted once, in the background, when reading ends.
    private func gather(folders: [URL], files: [MediaItem]) {
        rawItems = files
        items = files
        currentIndex = 0
        updateSections()

        let targets = folders
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { ScanTarget(folder: $0, root: root(for: $0)) }
        guard !targets.isEmpty else {
            isLoading = false
            rebuild(keepingCurrent: false)
            return
        }

        isLoading = true
        let skip = Set(files.map { $0.url.standardizedFileURL.path })
        loadTask = Task {
            for await batch in FileLister.scan(targets, skipping: skip) {
                guard !Task.isCancelled else { return }
                rawItems += batch
                items += batch
                updateSections()
                openSingleIfRequested()
            }
            guard !Task.isCancelled else { return }
            isLoading = false
            rebuild(keepingCurrent: true)
        }
    }

    /// Folder tile preview, read once per folder.
    func preview(for folder: URL) async -> FolderPreview {
        if let cached = previewCache[folder] { return cached }
        let preview = await Task.detached(priority: .utility) { FileLister.preview(of: folder) }.value
        previewCache[folder] = preview
        return preview
    }

    // MARK: ⌘-click picks

    func isPicked(_ url: URL) -> Bool {
        pickedFolders.contains(url) || pickedFiles[url] != nil
    }

    func togglePick(_ item: MediaItem) {
        if pickedFiles[item.url] != nil { pickedFiles[item.url] = nil } else { pickedFiles[item.url] = item }
    }

    func togglePick(folder: URL) {
        if pickedFolders.contains(folder) { pickedFolders.remove(folder) } else { pickedFolders.insert(folder) }
    }

    func clearPicks() {
        pickedFiles = [:]
        pickedFolders = []
        if browseMode == .picked { browseMode = .folder }
    }

    /// Gathers everything picked and opens it in the single view.
    func openPicked() {
        guard hasPicks else { return }
        openSingleWhenReady = true
        if browseMode != .picked { browseMode = .picked } else { refresh() }
        openSingleIfRequested()
    }

    private func openSingleIfRequested() {
        guard openSingleWhenReady, !items.isEmpty else { return }
        openSingleWhenReady = false
        currentIndex = 0
        viewMode = .single
    }

    // MARK: Sorting, paging and sections

    private var groupsByFolder: Bool { browseMode != .folder }

    /// Sorts in the background; only the finished order is handed to the views.
    private func rebuild(keepingCurrent: Bool) {
        arrangeGeneration += 1
        let generation = arrangeGeneration
        let keepID = keepingCurrent ? current?.id : nil
        let input = rawItems
        let settings = sort
        let group = groupsByFolder
        Task {
            let sorted = await Task.detached(priority: .userInitiated) {
                MediaLibrary.arrange(input, settings, groupByFolder: group)
            }.value
            guard generation == arrangeGeneration else { return }
            items = sorted
            if let keepID, let index = items.firstIndex(where: { $0.id == keepID }) {
                if index != currentIndex { currentIndex = index }
            } else {
                currentIndex = 0
            }
            updateSections()
            openSingleIfRequested()
            if items.isEmpty { viewMode = .grid }
        }
    }

    nonisolated static func sortedFolders(_ folders: [FolderEntry], _ settings: SortSettings) -> [URL] {
        folders.sorted { a, b in
            let order: ComparisonResult
            switch settings.folderKey {
            case .name: order = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
            case .date: order = compare(a.modified, b.modified)
            }
            if order == .orderedSame {
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            return settings.folderAscending ? order == .orderedAscending : order == .orderedDescending
        }
        .map(\.url)
    }

    /// Orders folders by the folder setting and files inside each folder by the file setting.
    nonisolated static func arrange(_ items: [MediaItem], _ settings: SortSettings, groupByFolder: Bool) -> [MediaItem] {
        guard groupByFolder else { return sortedFiles(items, settings) }

        let groups = Dictionary(grouping: items, by: \.folder)
        let folders = groups.keys.map { folder in
            FolderEntry(
                url: folder,
                modified: settings.folderKey == .date ? FileLister.modifiedDate(of: folder) : .distantPast
            )
        }
        let orderedFolders: [URL]
        if settings.folderKey == .name {
            // Full path, so subfolders follow their parent folder.
            orderedFolders = folders.map(\.url).sorted {
                let order = $0.path.localizedStandardCompare($1.path)
                return settings.folderAscending ? order == .orderedAscending : order == .orderedDescending
            }
        } else {
            orderedFolders = sortedFolders(folders, settings)
        }

        var result: [MediaItem] = []
        result.reserveCapacity(items.count)
        for folder in orderedFolders {
            result += sortedFiles(groups[folder] ?? [], settings)
        }
        return result
    }

    nonisolated static func sortedFiles(_ items: [MediaItem], _ settings: SortSettings) -> [MediaItem] {
        items.sorted { a, b in
            let order: ComparisonResult
            switch settings.fileKey {
            case .name: order = a.name.localizedStandardCompare(b.name)
            case .date: order = compare(a.modified, b.modified)
            case .size: order = compare(a.size, b.size)
            }
            if order == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return settings.fileAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    nonisolated private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    /// Called by the grid when its last rows come into view.
    func showMore() {
        guard displayLimit < items.count else { return }
        displayLimit += Self.pageSize
        updateSections()
    }

    /// Makes sure the grid includes this file (e.g. after moving far ahead in the single view).
    private func ensureDisplayed(_ index: Int) {
        guard index >= displayLimit else { return }
        displayLimit = (index / Self.pageSize + 2) * Self.pageSize
        updateSections()
    }

    private func updateSections() {
        let shown = min(displayLimit, items.count)
        guard shown > 0 else {
            sections = []
            return
        }
        guard groupsByFolder else {
            sections = [ItemSection(id: "files", title: "사진", range: 0..<shown)]
            return
        }
        var result: [ItemSection] = []
        var start = 0
        while start < shown {
            let folder = items[start].folder
            var end = start + 1
            while end < shown, items[end].folder == folder { end += 1 }
            result.append(ItemSection(
                id: "\(folder.path)#\(start)",
                title: FileLister.displayPath(of: folder, under: items[start].root),
                range: start..<end
            ))
            start = end
        }
        sections = result
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

    private var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Full screen shows only the picture. Opens the selected file first when in the grid.
    func toggleFullScreen() {
        if !isFullScreen, viewMode == .grid, current != nil { viewMode = .single }
        window?.toggleFullScreen(nil)
    }

    /// Image only, inside the window.
    func toggleImmersive() {
        if immersive {
            immersive = false
        } else {
            guard current != nil else { return }
            viewMode = .single
            immersive = true
        }
    }

    /// Called when the window enters or leaves full screen (by key, menu or the green button).
    func fullScreenChanged(_ isFullScreen: Bool) {
        if isFullScreen {
            if current != nil {
                viewMode = .single
                immersive = true
            }
        } else {
            immersive = false
        }
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
        case 49:                                                // space
            if viewMode == .single, current?.kind == .video {
                NotificationCenter.default.post(name: .toggleVideoPlayback, object: nil)
            } else {
                next()
            }
        case 121: next()                                        // page down
        case 116: previous()                                    // page up
        case 115: first()                                       // home
        case 119: last()                                        // end
        case 36, 76:                                            // return, enter
            toggleViewMode()
        case 51:                                                // delete (backspace)
            if inGrid, canGoUp { goUp() } else { return false }
        case 48:                                                // tab
            toggleImmersive()
        case 53:                                                // escape
            if isFullScreen {
                window?.toggleFullScreen(nil)
            } else if immersive {
                immersive = false
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
            if key == "h" {
                toggleImmersive()
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
