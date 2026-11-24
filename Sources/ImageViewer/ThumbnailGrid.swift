import SwiftUI

/// Thumbnails of every shown file, grouped by folder.
/// Click selects, double-click (or Return) opens the file in the single view.
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
                        ForEach(library.sections) { section in
                            Section {
                                ForEach(section.range, id: \.self) { index in
                                    cell(at: index)
                                }
                            } header: {
                                SectionHeader(section: section)
                            }
                        }
                    }
                    .padding(padding)
                }
                .onAppear {
                    scrollToCurrent(proxy, animated: false)
                }
                .onChange(of: library.currentIndex) {
                    scrollToCurrent(proxy, animated: true)
                }
            }
            .onChange(of: columnCount(for: geo.size.width), initial: true) { _, columns in
                library.gridColumns = columns
            }
        }
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
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct SectionHeader: View {
    let section: ItemSection

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(section.title)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(section.range.count)")
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
