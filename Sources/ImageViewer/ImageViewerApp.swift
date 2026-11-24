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
            }
            CommandMenu("보기") {
                Button("다음 파일") { library.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("이전 파일") { library.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
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
