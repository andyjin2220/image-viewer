import AppKit
import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// The folder the user picked that this file was found under.
    let root: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// Path shown to the user, relative to the picked folder (e.g. "작업/2024/a.png").
    var displayPath: String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return name }
        let relative = path.dropFirst(rootPath.count).drop(while: { $0 == "/" })
        return root.lastPathComponent + "/" + relative
    }
}

/// Holds the list of files found in the folders the user opened,
/// which one is on screen, and the current zoom.
@MainActor
final class MediaLibrary: ObservableObject {
    /// Formats macOS can decode on its own (ImageIO), including PSD.
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "psd", "bmp", "tif", "tiff", "heic", "heif", "webp",
    ]

    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var rootFolders: [URL] = []
    @Published private(set) var isScanning = false
    @Published var currentIndex: Int = 0 {
        didSet { if currentIndex != oldValue { zoom = nil } }
    }

    /// nil means "fit to window"; otherwise 1.0 is actual pixel size.
    @Published var zoom: CGFloat?

    /// Scale that fits the current image in the window. Kept up to date by the view.
    @Published var fitScale: CGFloat = 1

    private var scanTask: Task<Void, Never>?

    var current: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var effectiveZoom: CGFloat { zoom ?? fitScale }

    // MARK: Opening folders

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "열기"
        panel.message = "볼 폴더를 고르세요. 여러 개를 고를 수 있고, 하위 폴더까지 모두 불러와요."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        load(folders: panel.urls)
    }

    func load(folders: [URL]) {
        scanTask?.cancel()
        rootFolders = folders
        isScanning = true
        scanTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                MediaLibrary.scan(folders)
            }.value
            guard !Task.isCancelled else { return }
            self.items = found
            self.currentIndex = 0
            self.zoom = nil
            self.isScanning = false
        }
    }

    /// Walks every folder and all of its subfolders and returns supported files,
    /// sorted by path the way Finder sorts names (2 before 10).
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
            batch.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            result += batch.map { MediaItem(url: $0, root: folder) }
        }
        return result
    }

    // MARK: Navigation

    func next() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex + 1) % items.count
    }

    func previous() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex - 1 + items.count) % items.count
    }

    func first() {
        if !items.isEmpty { currentIndex = 0 }
    }

    func last() {
        if !items.isEmpty { currentIndex = items.count - 1 }
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

    func revealInFinder() {
        guard let url = current?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Keyboard

    /// Keys that have no menu shortcut. Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }

        switch event.keyCode {
        case 49: next()                 // space
        case 125, 121: next()           // down arrow, page down
        case 126, 116: previous()       // up arrow, page up
        case 115: first()               // home
        case 119: last()                // end
        case 53:                        // escape
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                return false
            }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen()
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
