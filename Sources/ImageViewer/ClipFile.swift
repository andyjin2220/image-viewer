import Foundation
import SQLite3

/// Reads the flattened preview image stored inside a Clip Studio Paint (.clip) file.
///
/// A .clip file starts with "CSFCHUNK" and is a list of chunks ("CHNKHead", "CHNKExta",
/// "CHNKSQLi", "CHNKFoot"), each an 8-byte name and an 8-byte big-endian length.
/// The "CHNKSQLi" chunk is a SQLite database whose CanvasPreview table holds a PNG of the whole canvas.
/// Layers are not read: the preview is the final picture Clip Studio saved with the file.
enum ClipFile {
    static func previewPNG(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        if let database = sqliteChunk(in: data) ?? sqliteByMagic(in: data) {
            return queryPreview(database)
        }
        return nil
    }

    private static func sqliteChunk(in data: Data) -> Data? {
        guard data.count > 24, data.prefix(8) == Data("CSFCHUNK".utf8) else { return nil }
        let base = data.startIndex
        var offset = 24
        while offset + 16 <= data.count {
            let name = data.subdata(in: (base + offset)..<(base + offset + 8))
            let length = data.subdata(in: (base + offset + 8)..<(base + offset + 16))
                .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let start = offset + 16
            guard length <= UInt64(data.count - start) else { return nil }
            let end = start + Int(length)
            if name == Data("CHNKSQLi".utf8) {
                return data.subdata(in: (base + start)..<(base + end))
            }
            offset = end
        }
        return nil
    }

    /// Fallback for files whose chunk list is not what we expect: find the SQLite header itself.
    private static func sqliteByMagic(in data: Data) -> Data? {
        guard let range = data.range(of: Data("SQLite format 3\0".utf8)) else { return nil }
        return data.subdata(in: range.lowerBound..<data.endIndex)
    }

    private static func queryPreview(_ database: Data) -> Data? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).sqlite")
        guard (try? database.write(to: tempURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ImageData FROM CanvasPreview LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
}
