import SwiftUI

@main
struct CameraRecorderApp: App {
    @StateObject private var cam = CameraManager()

    var body: some Scene {
        WindowGroup("Camera Recorder") {
            ContentView()
                .environmentObject(cam)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    SettingsWindowPresenter.shared.cam = cam
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Ajustes…") {
                    SettingsWindowPresenter.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
