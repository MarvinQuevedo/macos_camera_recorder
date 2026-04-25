import SwiftUI
import AVFoundation
import AppKit

struct ContentView: View {
    @EnvironmentObject var cam: CameraManager
    @State private var showError = false
    @State private var infoOpacity: Double = 0
    @State private var didAutoStart = false
    @State private var cleanMode = false

    var body: some View {
        ZStack {
            PreviewView(session: cam.session, mirror: cam.mirror)
                .background(Color.black)
                .ignoresSafeArea()

            if !cam.isRunning {
                emptyState
                    .transition(.opacity)
            }

            if cleanMode {
                cleanModeBubble
                    .transition(.opacity)
            } else {
                chromeOverlay
                    .transition(.opacity)
            }

            centerInfo

            if cam.isExporting {
                exportingOverlay
            }
        }
        .background(Color.black)
        .frame(minWidth: 720, minHeight: 480)
        .task {
            guard !didAutoStart else { return }
            didAutoStart = true
            if !cam.devices.isEmpty {
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
        .sheet(item: $cam.pendingRecording) { pending in
            RecordingActionSheet(
                pending: pending,
                videoFormat: cam.videoFormat,
                onSave: { cam.savePendingRecording() },
                onCopy: { cam.copyPendingRecordingToClipboard() },
                onDiscard: { cam.discardPendingRecording() }
            )
            .interactiveDismissDisabled(true)
        }
    }

    // MARK: - Chrome layout

    private var chromeOverlay: some View {
        VStack {
            HStack(alignment: .top) {
                topLeftCluster
                Spacer()
                topRightCluster
            }
            Spacer()
            bottomCluster
                .frame(maxWidth: .infinity)
        }
        .padding(20)
    }

    private var topLeftCluster: some View {
        HStack(spacing: 10) {
            cameraMenu
            if cam.isRecording { recordingBadge }
        }
    }

    private var topRightCluster: some View {
        HStack(spacing: 10) {
            GlassIconButton(
                systemName: "arrow.left.and.right",
                tooltip: cam.mirror ? "Desactivar espejo (⌘M)" : "Activar espejo (⌘M)",
                tint: cam.mirror ? .yellow : .white
            ) {
                cam.mirror.toggle()
            }
            .keyboardShortcut("m", modifiers: [.command])

            powerButton

            GlassIconButton(
                systemName: "gearshape.fill",
                tooltip: "Ajustes (⌘,)"
            ) {
                SettingsWindowPresenter.shared.show()
            }
            .keyboardShortcut(",", modifiers: [.command])

            GlassIconButton(
                systemName: "eye.slash",
                tooltip: "Modo limpio (⌘⇧H)"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { cleanMode = true }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        }
    }

    private var cleanModeBubble: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { cleanMode = false }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("Mostrar controles (⌘⇧H)")
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .padding(14)
            }
        }
    }

    private var bottomCluster: some View {
        HStack(spacing: 22) {
            Spacer()
            GlassIconButton(
                systemName: "camera.fill",
                tooltip: "Guardar foto (⌘S)"
            ) {
                cam.capturePhoto(toClipboard: false)
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!cam.isRunning)

            GlassIconButton(
                systemName: "doc.on.clipboard",
                tooltip: "Foto al portapapeles (⇧⌘C)"
            ) {
                cam.capturePhoto(toClipboard: true)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!cam.isRunning)

            recordButton

            Spacer()
        }
    }

    // MARK: - Camera menu

    private var cameraMenu: some View {
        Menu {
            if cam.devices.isEmpty {
                Text("Sin cámaras detectadas")
            } else {
                ForEach(cam.devices, id: \.uniqueID) { d in
                    Button {
                        cam.selectedDeviceID = d.uniqueID
                        Task { await cam.switchToSelectedDevice() }
                    } label: {
                        if cam.selectedDeviceID == d.uniqueID {
                            Label(deviceLabel(d), systemImage: "checkmark")
                        } else {
                            Text(deviceLabel(d))
                        }
                    }
                }
            }
            Divider()
            Button {
                cam.toggleFavoriteForCurrentSelection()
            } label: {
                Label(isCurrentFavorite ? "Quitar de favoritas" : "Marcar favorita",
                      systemImage: isCurrentFavorite ? "star.slash" : "star")
            }
            .disabled(cam.selectedDeviceID == nil)
            Button {
                cam.refreshDevices()
            } label: {
                Label("Recargar dispositivos", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                Text(currentDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text("REC \(formatTime(cam.recordingElapsed))")
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }

    private var powerButton: some View {
        Group {
            if cam.isRunning {
                GlassIconButton(systemName: "power", tooltip: "Detener (⌘.)") {
                    cam.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                GlassIconButton(systemName: "power", tooltip: "Iniciar (↵)", tint: .green) {
                    Task { await cam.start() }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(cam.devices.isEmpty)
            }
        }
    }

    private var recordButton: some View {
        Button {
            cam.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 64, height: 64)
                Circle()
                    .stroke(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 60, height: 60)
                if cam.isRecording {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.red)
                        .frame(width: 22, height: 22)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 46, height: 46)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command])
        .help(cam.isRecording ? "Detener grabación (⌘R)" : "Grabar (⌘R)")
        .disabled(!cam.isRunning && !cam.isRecording)
    }

    // MARK: - Empty / info / overlay

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: cam.devices.isEmpty ? "video.slash" : "video.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
            Text(cam.devices.isEmpty
                 ? "Conecta tu capturadora HDMI o cámara"
                 : "Iniciando cámara…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
            if cam.devices.isEmpty {
                Button("Buscar dispositivos") { cam.refreshDevices() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var centerInfo: some View {
        Group {
            if let info = cam.lastInfo {
                Text(info)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    .opacity(infoOpacity)
            }
        }
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Exportando…")
                    .foregroundStyle(.white)
                    .font(.callout.weight(.medium))
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Helpers

    private var isCurrentFavorite: Bool {
        guard let id = cam.selectedDeviceID, let fav = cam.favoriteDeviceID else { return false }
        return id == fav
    }

    private var currentDeviceName: String {
        guard let id = cam.selectedDeviceID,
              let d = cam.devices.first(where: { $0.uniqueID == id }) else {
            return "Sin cámara"
        }
        return deviceLabel(d)
    }

    private func deviceLabel(_ d: AVCaptureDevice) -> String {
        d.uniqueID == cam.favoriteDeviceID ? "★ \(d.localizedName)" : d.localizedName
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Glass icon button

private struct GlassIconButton: View {
    let systemName: String
    var tooltip: String = ""
    var tint: Color = .white
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Recording action sheet

private struct RecordingActionSheet: View {
    let pending: PendingRecording
    let videoFormat: VideoFormat
    let onSave: () -> Void
    let onCopy: () -> Void
    let onDiscard: () -> Void

    @State private var duration: String = ""
    @State private var sizeText: String = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            VStack(spacing: 4) {
                Text("Grabación lista")
                    .font(.title2.weight(.semibold))
                Text("Salida: \(videoFormat.label)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !duration.isEmpty || !sizeText.isEmpty {
                HStack(spacing: 14) {
                    if !duration.isEmpty {
                        Label(duration, systemImage: "clock")
                    }
                    if !sizeText.isEmpty {
                        Label(sizeText, systemImage: "internaldrive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    onDiscard()
                } label: {
                    Label("Descartar", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onCopy()
                } label: {
                    Label("Copiar", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button {
                    onSave()
                } label: {
                    Label("Guardar", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .task { await loadInfo() }
    }

    private func loadInfo() async {
        let asset = AVURLAsset(url: pending.url)
        if let secs = try? await asset.load(.duration).seconds, secs.isFinite {
            duration = formatTime(secs)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: pending.url.path),
           let bytes = attrs[.size] as? NSNumber {
            sizeText = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
