import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// The opened folder (sidebar root) this file lives under.
    let root: URL
    let modified: Date
    let size: Int

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var kind: MediaKind { MediaKind(url: url) }
    var folder: URL { FileLister.normalized(url.deletingLastPathComponent()) }

    /// Path shown to the user, relative to the opened folder (e.g. "작업/2024/a.png").
    var displayPath: String { FileLister.displayPath(of: url, under: root) }
}

enum MediaKind: Sendable {
    case image
    case video
    /// Clip Studio Paint file; shown through the preview image saved inside it.
    case clip

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) {
            self = .video
        } else if ext == "clip" {
            self = .clip
        } else {
            self = .image
        }
    }
}

struct FolderEntry: Hashable, Sendable {
    let url: URL
    let modified: Date
}

struct ScanTarget: Sendable {
    let folder: URL
    let root: URL
}

/// What a folder tile shows: one image to preview and how much is inside.
struct FolderPreview: Sendable {
    let imageURL: URL?
    let fileCount: Int
    let folderCount: Int
}

/// File system reads. Everything here is safe to call off the main thread.
enum FileLister {
    /// Formats macOS can decode on its own (ImageIO), including PSD.
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "psd", "bmp", "tif", "tiff", "heic", "heif", "webp",
        "mp4", "mov", "m4v", "clip",
    ]

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// One spelling per folder (no trailing-slash differences), so URLs compare equal.
    static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    static func isSameOrInside(_ path: String, _ folderPath: String) -> Bool {
        path == folderPath || path.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
    }

    static func displayPath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        let relative = path.dropFirst(rootPath.count).drop(while: { $0 == "/" })
        return relative.isEmpty ? root.lastPathComponent : root.lastPathComponent + "/" + relative
    }

    static func makeItem(_ url: URL, root: URL, values: URLResourceValues?) -> MediaItem {
        MediaItem(
            url: url,
            root: root,
            modified: values?.contentModificationDate ?? .distantPast,
            size: values?.fileSize ?? 0
        )
    }

    /// Lists one folder only (no subfolders are opened): its subfolders and its supported files.
    static func list(_ folder: URL, root: URL) -> (folders: [FolderEntry], files: [MediaItem]) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        var folders: [FolderEntry] = []
        var files: [MediaItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            if values?.isDirectory == true {
                if values?.isPackage != true {
                    folders.append(FolderEntry(url: normalized(url), modified: values?.contentModificationDate ?? .distantPast))
                }
            } else if isSupported(url) {
                files.append(makeItem(url, root: root, values: values))
            }
        }
        folders.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        return (folders, files)
    }

    static func subfolders(of folder: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .map(normalized)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Finds an image to show on a folder tile: the first one in the folder,
    /// or failing that, the first one a few levels down. Looks at no more than 30 folders.
    static func preview(of folder: URL) -> FolderPreview {
        let (folders, files) = list(folder, root: folder)
        var imageURL = files.min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }?.url
        var queue = folders.map(\.url)
        var visited = 0
        while imageURL == nil, !queue.isEmpty, visited < 30 {
            let next = queue.removeFirst()
            visited += 1
            let (subfolders, subfiles) = list(next, root: next)
            imageURL = subfiles.min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }?.url
            queue += subfolders.map(\.url)
        }
        return FolderPreview(imageURL: imageURL, fileCount: files.count, folderCount: folders.count)
    }

    /// Walks the folders and all their subfolders, handing back files in batches as they are found,
    /// so the first ones can be shown right away. Stops when the consumer stops listening.
    static func modifiedDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func scan(_ targets: [ScanTarget], skipping skipPaths: Set<String> = []) -> AsyncStream<[MediaItem]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var seen = skipPaths
                var batch: [MediaItem] = []
                var lastYield = Date()
                let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]

                for target in targets {
                    guard let enumerator = FileManager.default.enumerator(
                        at: target.folder,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) else { continue }

                    while let url = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }
                        guard isSupported(url) else { continue }
                        // A folder and one of its subfolders opened together must not list files twice.
                        guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                        batch.append(makeItem(url, root: target.root, values: try? url.resourceValues(forKeys: keys)))
                        if Date().timeIntervalSince(lastYield) > 0.5 {
                            continuation.yield(batch)
                            batch = []
                            lastYield = Date()
                        }
                    }
                }
                if !batch.isEmpty, !Task.isCancelled { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
