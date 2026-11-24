import AppKit
import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// The folder the user picked that this file was found under.
    let root: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var folder: URL { url.deletingLastPathComponent() }

    /// Path shown to the user, relative to the picked folder (e.g. "작업/2024/a.png").
    var displayPath: String { MediaLibrary.displayPath(of: url, under: root) }
}

/// A folder in the sidebar. Only folders that hold supported files (directly or below) appear.
struct FolderNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// Number of files in this folder and all of its subfolders.
    let count: Int
    let isRoot: Bool
    let children: [FolderNode]?

    var id: URL { url }
}

/// A run of files from one folder, shown as one section of the thumbnail grid.
struct ItemSection: Identifiable, Sendable {
    let folder: URL
    let title: String
    let range: Range<Int>

    var id: URL { folder }
}

enum ViewMode {
    case grid
    case single
}

/// Holds the folders the user opened, the files found in them, which ones are
/// shown, which one is selected, and the current zoom.
@MainActor
final class MediaLibrary: ObservableObject {
    /// Formats macOS can decode on its own (ImageIO), including PSD.
    nonisolated static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "psd", "bmp", "tif", "tiff", "heic", "heif", "webp",
    ]

    @Published private(set) var rootFolders: [URL] = []
    @Published private(set) var folderTree: [FolderNode] = []
    @Published private(set) var isScanning = false

    /// Every file found in the opened folders.
    private var allItems: [MediaItem] = []
    /// Files currently shown: all of them, or only those under the folders selected in the sidebar.
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var sections: [ItemSection] = []

    /// Folders selected in the sidebar. Empty means "show everything".
    @Published var selectedFolders: Set<URL> = [] {
        didSet { if selectedFolders != oldValue { applyFilter() } }
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

    private var scanTask: Task<Void, Never>?

    var current: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var effectiveZoom: CGFloat { zoom ?? fitScale }

    // MARK: Opening folders

    /// Replaces whatever is open with the folders the user picks.
    func chooseFolders() {
        guard let urls = pickFolders(prompt: "열기") else { return }
        load(folders: urls)
    }

    /// Keeps what is open and adds the folders the user picks.
    func addFolders() {
        guard let urls = pickFolders(prompt: "추가") else { return }
        var roots = rootFolders
        for url in urls where !roots.contains(url) { roots.append(url) }
        load(folders: roots)
    }

    func removeRoot(_ url: URL) {
        load(folders: rootFolders.filter { $0 != url })
    }

    private func pickFolders(prompt: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        panel.message = "볼 폴더를 고르세요. ⌘를 누른 채 클릭하면 여러 개를 고를 수 있고, 하위 폴더까지 모두 불러와요."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    func load(folders: [URL]) {
        scanTask?.cancel()
        let previousSelection = selectedFolders
        rootFolders = folders
        isScanning = !folders.isEmpty
        scanTask = Task {
            let (found, tree) = await Task.detached(priority: .userInitiated) {
                let found = MediaLibrary.scan(folders)
                return (found, MediaLibrary.buildTree(roots: folders, items: found))
            }.value
            guard !Task.isCancelled else { return }
            self.allItems = found
            self.folderTree = tree
            let stillThere = Set(Self.flatten(tree).map(\.url))
            // Assigning selectedFolders re-filters only when it changes, so filter explicitly too.
            self.selectedFolders = previousSelection.intersection(stillThere)
            self.applyFilter()
            self.isScanning = false
        }
    }

    private func applyFilter() {
        if selectedFolders.isEmpty {
            items = allItems
        } else {
            let prefixes = selectedFolders.map { $0.standardizedFileURL.path }
            items = allItems.filter { item in
                let dir = item.folder.standardizedFileURL.path
                return prefixes.contains { dir == $0 || dir.hasPrefix($0 + "/") }
            }
        }
        sections = Self.makeSections(items)
        currentIndex = 0
        zoom = nil
        viewMode = .grid
    }

    // MARK: Scanning (runs off the main thread)

    /// Walks every folder and all of its subfolders and returns supported files.
    /// Files are grouped by folder, and names are sorted the way Finder sorts them (2 before 10).
    nonisolated static func scan(_ folders: [URL]) -> [MediaItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [MediaItem] = []

        for folder in folders {
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var batch: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                // Opening a folder and one of its subfolders together must not list files twice.
                if seen.insert(url.standardizedFileURL.path).inserted {
                    batch.append(url)
                }
            }
            batch.sort { a, b in
                let dirOrder = a.deletingLastPathComponent().path
                    .localizedStandardCompare(b.deletingLastPathComponent().path)
                if dirOrder != .orderedSame { return dirOrder == .orderedAscending }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            result += batch.map { MediaItem(url: $0, root: folder) }
        }
        return result
    }

    nonisolated static func buildTree(roots: [URL], items: [MediaItem]) -> [FolderNode] {
        var direct: [String: Int] = [:]
        for item in items {
            direct[item.folder.standardizedFileURL.path, default: 0] += 1
        }

        var childrenOf: [String: Set<String>] = [:]
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            for dir in direct.keys where dir.hasPrefix(rootPath + "/") {
                var cur = dir
                while cur != rootPath, cur.count > rootPath.count {
                    let parent = (cur as NSString).deletingLastPathComponent
                    childrenOf[parent, default: []].insert(cur)
                    cur = parent
                }
            }
        }

        func make(_ path: String, isRoot: Bool) -> FolderNode {
            let kids = (childrenOf[path] ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { make($0, isRoot: false) }
            let total = direct[path, default: 0] + kids.reduce(0) { $0 + $1.count }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return FolderNode(
                url: url,
                name: url.lastPathComponent,
                count: total,
                isRoot: isRoot,
                children: kids.isEmpty ? nil : kids
            )
        }

        return roots.map { make($0.standardizedFileURL.path, isRoot: true) }
    }

    nonisolated static func flatten(_ nodes: [FolderNode]) -> [FolderNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    nonisolated static func makeSections(_ items: [MediaItem]) -> [ItemSection] {
        var sections: [ItemSection] = []
        var start = 0
        while start < items.count {
            let folder = items[start].folder
            var end = start + 1
            while end < items.count, items[end].folder == folder { end += 1 }
            sections.append(ItemSection(
                folder: folder,
                title: displayPath(of: folder, under: items[start].root),
                range: start..<end
            ))
            start = end
        }
        return sections
    }

    nonisolated static func displayPath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        let relative = path.dropFirst(rootPath.count).drop(while: { $0 == "/" })
        return relative.isEmpty ? root.lastPathComponent : root.lastPathComponent + "/" + relative
    }

    // MARK: Navigation

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    func open(_ index: Int) {
        select(index)
        viewMode = .single
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
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }

        // Let the sidebar's folder list use the arrow keys itself.
        if NSApp.keyWindow?.firstResponder is NSTableView { return false }

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
        case 53:                                                // escape
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else if viewMode == .single {
                viewMode = .grid
            } else {
                return false
            }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen()
            case "+", "=": if inGrid { return false } else { zoomIn() }
            case "-": if inGrid { return false } else { zoomOut() }
            case "0": if inGrid { return false } else { zoomToFit() }
            case "1": if inGrid { return false } else { zoomActualSize() }
            default: return false
            }
        }
        return true
    }
}
