import AppKit
import SwiftUI

@main
struct ImageViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = MediaLibrary()

    var body: some Scene {
        WindowGroup("이미지 뷰어") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("폴더 열기…") { library.chooseFolders() }
                    .keyboardShortcut("o")
                Button("폴더 추가…") { library.addFolders() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("모든 폴더 닫기") { library.closeAllFolders() }
                    .disabled(library.rootFolders.isEmpty)
            }
            CommandMenu("보기") {
                Button("썸네일 / 한 장씩 보기 전환") { library.toggleViewMode() }
                    .keyboardShortcut("g")
                Divider()
                // ← → and the other plain keys are handled in MediaLibrary.handleKey
                // so the sidebar's folder list can still use them when it has focus.
                Button("다음 파일 (→)") { library.next() }
                Button("이전 파일 (←)") { library.previous() }
                Divider()
                Button("확대") { library.zoomIn() }
                    .keyboardShortcut("=")
                Button("축소") { library.zoomOut() }
                    .keyboardShortcut("-")
                Button("화면에 맞추기") { library.zoomToFit() }
                    .keyboardShortcut("0")
                Button("실제 크기") { library.zoomActualSize() }
                    .keyboardShortcut("1")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
