import SwiftUI

/// Folder tiles (in folder mode) and thumbnails of the shown files.
/// Click selects, double-click (or Return) opens a file; double-clicking a folder goes into it.
struct ThumbnailGrid: View {
    @EnvironmentObject private var library: MediaLibrary
    let thumbSize: CGFloat

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize), spacing: spacing)],
                        alignment: .leading,
                        spacing: spacing,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        if library.browseMode == .folder, !library.subfolders.isEmpty {
                            Section {
                                ForEach(library.subfolders, id: \.self) { folder in
                                    FolderTile(folder: folder, size: thumbSize)
                                        .onTapGesture(count: 2) { library.enter(folder) }
                                        .contextMenu {
                                            Button("열기") { library.enter(folder) }
                                            Button("Finder에서 보기") { library.revealInFinder(folder) }
                                        }
                                }
                            } header: {
                                SectionHeader(title: "폴더", count: library.subfolders.count)
                            }
                        }

                        ForEach(library.sections) { section in
                            Section {
                                ForEach(section.range, id: \.self) { index in
                                    cell(at: index)
                                }
                            } header: {
                                SectionHeader(title: section.title, count: section.range.count)
                            }
                        }
                    }
                    .padding(padding)
                }
                .id(gridIdentity)
                .onAppear { scrollToCurrent(proxy, animated: false) }
                .onChange(of: library.currentIndex) { scrollToCurrent(proxy, animated: true) }
            }
            .onChange(of: columnCount(for: geo.size.width), initial: true) { _, columns in
                library.gridColumns = columns
            }
        }
    }

    /// A new place starts scrolled to the top.
    private var gridIdentity: String {
        "\(library.browseMode)-\(library.currentFolder?.path ?? "")"
    }

    @ViewBuilder
    private func cell(at index: Int) -> some View {
        if library.items.indices.contains(index) {
            let item = library.items[index]
            ThumbnailCell(item: item, size: thumbSize, isSelected: index == library.currentIndex)
                .id(item.id)
                .onTapGesture(count: 2) { library.open(index) }
                .simultaneousGesture(TapGesture().onEnded { library.select(index) })
                .contextMenu {
                    Button("열기") { library.open(index) }
                    Button("Finder에서 보기") { library.revealInFinder(item.url) }
                }
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        max(1, Int((width - padding * 2 + spacing) / (thumbSize + spacing)))
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = library.current?.id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
        .font(.headline)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(.bar)
    }
}

/// A folder shown as a tile, with the first image found inside as its picture.
struct FolderTile: View {
    @EnvironmentObject private var library: MediaLibrary
    let folder: URL
    let size: CGFloat

    @State private var preview: FolderPreview?
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))

                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipped()
                    } else if preview == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: size * 0.3))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size, height: size)

                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                    if let preview {
                        if preview.fileCount > 0 { Text("사진 \(preview.fileCount)") }
                        if preview.folderCount > 0 { Text("폴더 \(preview.folderCount)") }
                    }
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(6)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(folder.lastPathComponent)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
        }
        .contentShape(Rectangle())
        .help(folder.path)
        .task(id: folder) {
            let result = await library.preview(for: folder)
            guard !Task.isCancelled else { return }
            preview = result
            if let url = result.imageURL {
                let thumb = await ThumbnailCache.shared.thumbnail(for: url)
                guard !Task.isCancelled else { return }
                image = thumb
            }
        }
    }
}

struct ThumbnailCell: View {
    let item: MediaItem
    let size: CGFloat
    let isSelected: Bool

    @State private var image: CGImage?
    @State private var failed = false

    private static let plainExtensions: Set<String> = ["png", "jpg", "jpeg"]

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))

                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else if failed {
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                let ext = item.url.pathExtension.lowercased()
                if !Self.plainExtensions.contains(ext) {
                    Text(ext.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .help(item.displayPath)
        .task(id: item.url) {
            failed = false
            let result = await ThumbnailCache.shared.thumbnail(for: item.url)
            guard !Task.isCancelled else { return }
            image = result
            failed = result == nil
        }
    }
}
