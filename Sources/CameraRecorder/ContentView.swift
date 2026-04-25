import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var showError = false
    @State private var infoOpacity: Double = 0
    @State private var didAutoStart = false

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            controls.padding(12)
        }
        .task {
            // Auto-iniciar al abrir si está habilitado y hay cámara disponible.
            guard !didAutoStart else { return }
            didAutoStart = true
            if cam.autoStart, !cam.devices.isEmpty {
                await cam.start()
            }
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
            PreviewView(session: cam.session, mirror: cam.mirror)
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
                        Text(deviceLabel(d)).tag(d.uniqueID)
                    }
                }
                .frame(maxWidth: 360)
                .onChange(of: cam.selectedDeviceID) { _ in
                    Task { await cam.switchToSelectedDevice() }
                }

                Button {
                    cam.toggleFavoriteForCurrentSelection()
                } label: {
                    Image(systemName: isCurrentFavorite ? "star.fill" : "star")
                        .foregroundStyle(isCurrentFavorite ? .yellow : .secondary)
                }
                .help(isCurrentFavorite ? "Quitar de favoritas" : "Marcar como favorita")
                .disabled(cam.selectedDeviceID == nil)

                Button {
                    cam.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Recargar dispositivos")

                Spacer()

                if cam.isRunning {
                    Button("Detener") { cam.stop() }
                } else {
                    Button("Iniciar") { Task { await cam.start() } }
                        .keyboardShortcut(.return)
                        .disabled(cam.devices.isEmpty)
                }
            }

            HStack(spacing: 12) {
                Picker("Resolución", selection: $cam.resolution) {
                    ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 240)

                Picker("FPS", selection: $cam.frameRate) {
                    ForEach(FrameRatePreset.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 160)

                Picker("Foto", selection: $cam.photoFormat) {
                    ForEach(PhotoFormat.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 140)

                Toggle("Espejo", isOn: $cam.mirror)
                    .toggleStyle(.checkbox)

                Toggle("Audio", isOn: $cam.includeAudio)
                    .toggleStyle(.checkbox)
                    .disabled(cam.isRunning)

                Toggle("Auto-iniciar", isOn: $cam.autoStart)
                    .toggleStyle(.checkbox)
                    .help("Encender la cámara favorita al abrir la app")

                Spacer()
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

    private var isCurrentFavorite: Bool {
        guard let id = cam.selectedDeviceID, let fav = cam.favoriteDeviceID else { return false }
        return id == fav
    }

    private func deviceLabel(_ d: AVCaptureDevice) -> String {
        if d.uniqueID == cam.favoriteDeviceID {
            return "★ \(d.localizedName)"
        }
        return d.localizedName
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
