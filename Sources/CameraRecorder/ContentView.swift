import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var showError = false
    @State private var infoOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            controls.padding(12)
        }
        .onChange(of: cam.lastError) { newValue in showError = newValue != nil }
        .onChange(of: cam.lastInfo) { newValue in
            guard newValue != nil else { return }
            withAnimation(.easeIn(duration: 0.15)) { infoOpacity = 1 }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(.easeOut(duration: 0.4)) { infoOpacity = 0 }
                try? await Task.sleep(nanoseconds: 400_000_000)
                cam.lastInfo = nil
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { cam.lastError = nil }
        } message: {
            Text(cam.lastError ?? "")
        }
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            PreviewView(session: cam.session)
                .background(Color.black)
                .frame(minHeight: 380)

            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                        .opacity(0.9)
                    Text("REC \(formatTime(cam.recordingElapsed))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(10)
            }

            if let info = cam.lastInfo {
                Text(info)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
                    .opacity(infoOpacity)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Cámara", selection: Binding(
                    get: { cam.selectedDeviceID ?? "" },
                    set: { cam.selectedDeviceID = $0.isEmpty ? nil : $0 }
                )) {
                    if cam.devices.isEmpty {
                        Text("Sin cámaras detectadas").tag("")
                    }
                    ForEach(cam.devices, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(d.uniqueID)
                    }
                }
                .frame(maxWidth: 360)
                .onChange(of: cam.selectedDeviceID) { _ in
                    Task { await cam.switchToSelectedDevice() }
                }

                Button {
                    cam.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Recargar dispositivos")

                Toggle("Audio", isOn: $cam.includeAudio)
                    .toggleStyle(.checkbox)
                    .disabled(cam.isRunning)

                Spacer()

                if cam.isRunning {
                    Button("Detener") { cam.stop() }
                } else {
                    Button("Iniciar") { Task { await cam.start() } }
                        .keyboardShortcut(.return)
                        .disabled(cam.devices.isEmpty)
                }
            }

            HStack(spacing: 8) {
                Button {
                    cam.capturePhoto(toClipboard: false)
                } label: {
                    Label("Guardar imagen", systemImage: "camera")
                }
                .disabled(!cam.isRunning)
                .keyboardShortcut("s", modifiers: [.command])

                Button {
                    cam.capturePhoto(toClipboard: true)
                } label: {
                    Label("Imagen al portapapeles", systemImage: "doc.on.clipboard")
                }
                .disabled(!cam.isRunning)
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Spacer()

                if cam.isRecording {
                    Button(role: .destructive) {
                        cam.stopRecording()
                    } label: {
                        Label("Detener grabación", systemImage: "stop.circle.fill")
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                } else {
                    Button {
                        cam.startRecording()
                    } label: {
                        Label("Grabar video", systemImage: "record.circle")
                    }
                    .disabled(!cam.isRunning)
                    .keyboardShortcut("r", modifiers: [.command])
                }

                Button {
                    cam.saveLastVideoAs()
                } label: {
                    Label("Guardar video", systemImage: "square.and.arrow.down")
                }
                .disabled(cam.lastVideoURL == nil)

                Button {
                    cam.copyLastVideoToClipboard()
                } label: {
                    Label("Video al portapapeles", systemImage: "doc.on.clipboard.fill")
                }
                .disabled(cam.lastVideoURL == nil)
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
