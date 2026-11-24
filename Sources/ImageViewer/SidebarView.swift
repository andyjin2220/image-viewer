import SwiftUI

/// The opened folders and their subfolders. Selecting one or more (⌘-click)
/// shows only the files under them; selecting nothing shows everything.
struct SidebarView: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        VStack(spacing: 0) {
            if library.rootFolders.isEmpty {
                VStack(spacing: 8) {
                    Text("열린 폴더가 없어요")
                        .foregroundStyle(.secondary)
                    Button("폴더 열기…") { library.chooseFolders() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $library.selectedFolders) {
                    Section("폴더") {
                        OutlineGroup(library.folderTree, children: \.children) { node in
                            FolderRow(node: node)
                                .tag(node.url)
                                .contextMenu { contextMenu(for: node) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack(spacing: 4) {
                Button { library.addFolders() } label: {
                    Image(systemName: "plus")
                }
                .help("폴더 추가 (⇧⌘O)")

                Spacer()

                if !library.selectedFolders.isEmpty {
                    Button("전체 보기") { library.selectedFolders = [] }
                        .help("폴더 선택을 풀고 모든 파일을 보여줘요")
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private func contextMenu(for node: FolderNode) -> some View {
        Button("이 폴더만 보기") { library.selectedFolders = [node.url] }
        Button("Finder에서 보기") { library.revealInFinder(node.url) }
        if node.isRoot {
            Divider()
            Button("목록에서 빼기") { library.removeRoot(node.url) }
        }
    }
}

private struct FolderRow: View {
    let node: FolderNode

    var body: some View {
        Label {
            HStack {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(node.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } icon: {
            Image(systemName: node.isRoot ? "folder.fill" : "folder")
        }
        .help(node.url.path)
    }
}
