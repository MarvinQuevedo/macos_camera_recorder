import SwiftUI

@main
struct CameraRecorderApp: App {
    var body: some Scene {
        WindowGroup("Camera Recorder") {
            ContentView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}
