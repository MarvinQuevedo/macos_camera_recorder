import SwiftUI
import AVFoundation
import AppKit

struct SettingsView: View {
    @EnvironmentObject var cam: CameraManager

    var body: some View {
        TabView {
            VideoTab()
                .tabItem { Label("Video", systemImage: "video") }
            PhotoTab()
                .tabItem { Label("Foto", systemImage: "camera") }
            DeviceTab()
                .tabItem { Label("Dispositivo", systemImage: "rectangle.connected.to.line.below") }
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }
}

private struct VideoTab: View {
    @EnvironmentObject var cam: CameraManager

    var body: some View {
        Form {
            Section("Captura") {
                Picker("Resolución", selection: $cam.resolution) {
                    ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("FPS", selection: $cam.frameRate) {
                    ForEach(FrameRatePreset.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Incluir audio", isOn: $cam.includeAudio)
                    .disabled(cam.isRecording)
                if cam.isRecording {
                    Text("Detén la grabación para cambiar el audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Salida") {
                Picker("Formato de video", selection: $cam.videoFormat) {
                    ForEach(VideoFormat.allCases) { Text($0.label).tag($0) }
                }
                Text("La grabación interna es MOV; al guardar o copiar se exporta al formato seleccionado.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PhotoTab: View {
    @EnvironmentObject var cam: CameraManager

    var body: some View {
        Form {
            Section("Foto") {
                Picker("Formato", selection: $cam.photoFormat) {
                    ForEach(PhotoFormat.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Espejo en preview y captura", isOn: $cam.mirror)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeviceTab: View {
    @EnvironmentObject var cam: CameraManager

    var body: some View {
        Form {
            Section("Dispositivo activo") {
                Picker("Cámara", selection: Binding(
                    get: { cam.selectedDeviceID ?? "" },
                    set: { cam.selectedDeviceID = $0.isEmpty ? nil : $0 }
                )) {
                    if cam.devices.isEmpty {
                        Text("Sin cámaras detectadas").tag("")
                    }
                    ForEach(cam.devices, id: \.uniqueID) { d in
                        Text(label(for: d)).tag(d.uniqueID)
                    }
                }
                .onChange(of: cam.selectedDeviceID) { _ in
                    Task { await cam.switchToSelectedDevice() }
                }

                HStack {
                    Button {
                        cam.toggleFavoriteForCurrentSelection()
                    } label: {
                        Label(isFavorite ? "Quitar favorita" : "Marcar como favorita",
                              systemImage: isFavorite ? "star.slash" : "star")
                    }
                    .disabled(cam.selectedDeviceID == nil)

                    Spacer()

                    Button {
                        cam.refreshDevices()
                    } label: {
                        Label("Recargar", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section("Comportamiento") {
                Text("La cámara favorita se inicia automáticamente al abrir la app y al conectar dispositivos nuevos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var isFavorite: Bool {
        guard let id = cam.selectedDeviceID, let fav = cam.favoriteDeviceID else { return false }
        return id == fav
    }

    private func label(for d: AVCaptureDevice) -> String {
        d.uniqueID == cam.favoriteDeviceID ? "★ \(d.localizedName)" : d.localizedName
    }
}

// MARK: - Window presenter (NSWindow-based, robust)

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    weak var cam: CameraManager?
    private var window: NSWindow?

    func show() {
        guard let cam else {
            NSSound.beep()
            return
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView().environmentObject(cam)
        let hosting = NSHostingController(rootView: root)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Ajustes"
        newWindow.styleMask = [.titled, .closable, .resizable]
        newWindow.setContentSize(NSSize(width: 460, height: 360))
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.delegate = WindowDelegate.shared
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        static let shared = WindowDelegate()
    }
}
