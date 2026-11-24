import AppKit
import SwiftUI

/// The opened folders. Subfolders are read only when a folder is expanded.
/// Click shows a folder; ⌘-click selects several and gathers all of their files.
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
                List {
                    Section("폴더") {
                        ForEach(library.rootNodes) { node in
                            FolderTreeRow(node: node)
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

                Button { library.removeRoots(library.selectedRoots) } label: {
                    Image(systemName: "minus")
                }
                .help("고른 폴더를 목록에서 빼요 (폴더와 파일은 지워지지 않아요)")
                .disabled(library.selectedRoots.isEmpty)

                Spacer()

                if !library.selectedFolders.isEmpty {
                    Button("선택 풀기") { library.showEverything() }
                        .help("폴더 선택을 풀어요")
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 200)
    }
}

private struct FolderTreeRow: View {
    @EnvironmentObject private var library: MediaLibrary
    @ObservedObject var node: FolderNode
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let children = node.children, !children.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children) { child in
                        FolderTreeRow(node: child)
                    }
                } label: {
                    label
                }
            } else {
                label
            }
        }
        // Only this folder's own listing is read, to know whether it has subfolders.
        .task { await node.loadChildren() }
    }

    private var label: some View {
        let isSelected = library.selectedFolders.contains(node.url)
        return Label {
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: node.isRoot ? "folder.fill" : "folder")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            library.sidebarClick(node.url, toggle: NSEvent.modifierFlags.contains(.command))
        }
        .help(node.url.path)
        .contextMenu {
            Button("이 폴더 보기") { library.enter(node.url) }
            Button("Finder에서 보기") { library.revealInFinder(node.url) }
            if node.isRoot {
                Divider()
                Button("목록에서 빼기 (파일은 그대로)") { library.removeRoot(node.url) }
            }
        }
    }
}
