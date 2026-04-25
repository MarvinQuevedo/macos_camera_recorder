import AVFoundation
import AppKit
import Combine
import CoreMedia
import UniformTypeIdentifiers

@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String? {
        didSet {
            if let id = selectedDeviceID {
                UserDefaults.standard.set(id, forKey: SettingsKey.lastDeviceID)
            }
        }
    }
    @Published var favoriteDeviceID: String? {
        didSet {
            let d = UserDefaults.standard
            if let id = favoriteDeviceID { d.set(id, forKey: SettingsKey.favoriteDeviceID) }
            else { d.removeObject(forKey: SettingsKey.favoriteDeviceID) }
        }
    }
    @Published var includeAudio: Bool {
        didSet {
            UserDefaults.standard.set(includeAudio, forKey: SettingsKey.includeAudio)
            if isRunning { Task { await applyAudioInput() } }
        }
    }
    @Published var resolution: ResolutionPreset {
        didSet {
            UserDefaults.standard.set(resolution.rawValue, forKey: SettingsKey.resolution)
            if isRunning { applyResolutionAndFrameRate() }
        }
    }
    @Published var frameRate: FrameRatePreset {
        didSet {
            UserDefaults.standard.set(frameRate.rawValue, forKey: SettingsKey.frameRate)
            if isRunning { applyResolutionAndFrameRate() }
        }
    }
    @Published var mirror: Bool {
        didSet {
            UserDefaults.standard.set(mirror, forKey: SettingsKey.mirror)
            applyMirror()
        }
    }
    @Published var photoFormat: PhotoFormat {
        didSet { UserDefaults.standard.set(photoFormat.rawValue, forKey: SettingsKey.photoFormat) }
    }
    @Published var videoFormat: VideoFormat {
        didSet { UserDefaults.standard.set(videoFormat.rawValue, forKey: SettingsKey.videoFormat) }
    }

    @Published var isRunning: Bool = false
    @Published var isRecording: Bool = false
    @Published var isExporting: Bool = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var pendingRecording: PendingRecording?
    @Published var lastError: String?
    @Published var lastInfo: String?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var photoDelegate: PhotoCaptureDelegate?
    private var recTimer: Timer?
    private var recStart: Date?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    override init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            SettingsKey.includeAudio: true,
            SettingsKey.resolution: ResolutionPreset.auto.rawValue,
            SettingsKey.frameRate: FrameRatePreset.auto.rawValue,
            SettingsKey.mirror: false,
            SettingsKey.photoFormat: PhotoFormat.jpeg.rawValue,
            SettingsKey.videoFormat: VideoFormat.mp4.rawValue
        ])
        self.includeAudio = d.bool(forKey: SettingsKey.includeAudio)
        self.resolution = ResolutionPreset(rawValue: d.string(forKey: SettingsKey.resolution) ?? "") ?? .auto
        self.frameRate = FrameRatePreset(rawValue: d.integer(forKey: SettingsKey.frameRate)) ?? .auto
        self.mirror = d.bool(forKey: SettingsKey.mirror)
        self.photoFormat = PhotoFormat(rawValue: d.string(forKey: SettingsKey.photoFormat) ?? "") ?? .jpeg
        self.videoFormat = VideoFormat(rawValue: d.string(forKey: SettingsKey.videoFormat) ?? "") ?? .mp4
        self.favoriteDeviceID = d.string(forKey: SettingsKey.favoriteDeviceID)
        super.init()

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        refreshDevices()
        installDeviceObservers()
    }

    deinit {
        if let o = connectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = disconnectObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Devices

    func refreshDevices() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.external, .continuityCamera, .deskViewCamera])
        } else {
            types.append(.deskViewCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        devices = discovery.devices

        let preferredID = preferredInitialDeviceID()
        if selectedDeviceID == nil || !devices.contains(where: { $0.uniqueID == selectedDeviceID }) {
            selectedDeviceID = preferredID
        }
    }

    private func preferredInitialDeviceID() -> String? {
        if let fav = favoriteDeviceID, devices.contains(where: { $0.uniqueID == fav }) {
            return fav
        }
        let last = UserDefaults.standard.string(forKey: SettingsKey.lastDeviceID)
        if let last, devices.contains(where: { $0.uniqueID == last }) {
            return last
        }
        return devices.first?.uniqueID
    }

    func toggleFavoriteForCurrentSelection() {
        guard let id = selectedDeviceID else { return }
        if favoriteDeviceID == id {
            favoriteDeviceID = nil
            lastInfo = "Favorita eliminada"
        } else {
            favoriteDeviceID = id
            lastInfo = "Marcada como favorita"
        }
    }

    private func installDeviceObservers() {
        let center = NotificationCenter.default
        connectObserver = center.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDevices()
                if !self.isRunning, !self.devices.isEmpty {
                    await self.start()
                }
            }
        }
        disconnectObserver = center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    // MARK: - Session

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            lastError = "Permiso de cámara denegado"
            return
        }
        if includeAudio {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.uniqueID == id }) ?? AVCaptureDevice(uniqueID: id) else {
            lastError = "No hay dispositivo de cámara disponible"
            return
        }
        configure(videoDevice: device)
        let s = session
        await Task.detached(priority: .userInitiated) {
            if !s.isRunning { s.startRunning() }
        }.value
        isRunning = session.isRunning
        applyResolutionAndFrameRate()
        applyMirror()
    }

    func stop() {
        if movieOutput.isRecording { movieOutput.stopRecording() }
        let s = session
        Task.detached(priority: .userInitiated) {
            if s.isRunning { s.stopRunning() }
        }
        isRunning = false
    }

    func switchToSelectedDevice() async {
        guard isRunning,
              let id = selectedDeviceID,
              let device = devices.first(where: { $0.uniqueID == id }) else { return }
        configure(videoDevice: device)
        applyResolutionAndFrameRate()
        applyMirror()
    }

    private func configure(videoDevice: AVCaptureDevice) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = resolution.sessionPreset

        if let videoInput { session.removeInput(videoInput) }
        if let audioInput { session.removeInput(audioInput); self.audioInput = nil }

        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
        } catch {
            lastError = "No se pudo abrir la cámara: \(error.localizedDescription)"
            return
        }

        if includeAudio, let audioDevice = AVCaptureDevice.default(for: .audio) {
            if let aInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(aInput) {
                session.addInput(aInput)
                audioInput = aInput
            }
        }
    }

    private func applyResolutionAndFrameRate() {
        if session.sessionPreset != resolution.sessionPreset,
           session.canSetSessionPreset(resolution.sessionPreset) {
            session.beginConfiguration()
            session.sessionPreset = resolution.sessionPreset
            session.commitConfiguration()
        }

        guard frameRate != .auto, let device = videoInput?.device else { return }
        let target = Double(frameRate.rawValue)
        let supports = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= target && $0.maxFrameRate >= target
        }
        guard supports else { return }
        do {
            try device.lockForConfiguration()
            let dur = CMTime(value: 1, timescale: Int32(frameRate.rawValue))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            device.unlockForConfiguration()
        } catch {
            // El frame rate es un nice-to-have; si falla, el preset por defecto se mantiene.
        }
    }

    private func applyAudioInput() async {
        if movieOutput.isRecording {
            lastError = "Detén la grabación antes de cambiar el audio"
            return
        }
        if includeAudio {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        session.beginConfiguration()
        if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
        if includeAudio, let audioDevice = AVCaptureDevice.default(for: .audio),
           let aInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(aInput) {
            session.addInput(aInput)
            audioInput = aInput
        }
        session.commitConfiguration()
    }

    func applyMirror() {
        let connections: [AVCaptureConnection] = [
            photoOutput.connection(with: .video),
            movieOutput.connection(with: .video)
        ].compactMap { $0 }
        for conn in connections where conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = mirror
        }
    }

    // MARK: - Photo

    func capturePhoto(toClipboard: Bool) {
        guard isRunning else { return }
        let settings: AVCapturePhotoSettings
        if photoFormat == .jpeg, photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        let delegate = PhotoCaptureDelegate { [weak self] image in
            Task { @MainActor in
                guard let self else { return }
                guard let image else {
                    self.lastError = "No se pudo capturar la imagen"
                    return
                }
                if toClipboard {
                    self.copyImageToClipboard(image)
                    self.lastInfo = "Imagen copiada al portapapeles"
                } else {
                    self.savePhoto(image)
                }
                self.photoDelegate = nil
            }
        }
        photoDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func copyImageToClipboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func savePhoto(_ image: NSImage) {
        let panel = NSSavePanel()
        let preferJPEG = photoFormat == .jpeg
        panel.allowedContentTypes = preferJPEG ? [.jpeg, .png] : [.png, .jpeg]
        let ext = preferJPEG ? "jpg" : "png"
        panel.nameFieldStringValue = "captura-\(timestamp()).\(ext)"
        panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                self?.lastError = "No se pudo codificar la imagen"
                return
            }
            let urlExt = url.pathExtension.lowercased()
            let isJPEG = urlExt == "jpg" || urlExt == "jpeg"
            let type: NSBitmapImageRep.FileType = isJPEG ? .jpeg : .png
            let props: [NSBitmapImageRep.PropertyKey: Any] = isJPEG
                ? [.compressionFactor: 0.92]
                : [:]
            do {
                guard let data = rep.representation(using: type, properties: props) else {
                    self?.lastError = "No se pudo codificar la imagen"
                    return
                }
                try data.write(to: url, options: .atomic)
                Task { @MainActor in self?.lastInfo = "Imagen guardada" }
            } catch {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Video

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard isRunning, !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(timestamp()).mov")
        try? FileManager.default.removeItem(at: url)

        movieOutput.startRecording(to: url, recordingDelegate: self)
        recStart = Date()
        recordingElapsed = 0
        recTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.recStart else { return }
                self.recordingElapsed = Date().timeIntervalSince(s)
            }
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        recTimer?.invalidate()
        recTimer = nil
    }

    // MARK: - Pending recording actions

    func savePendingRecording() {
        guard let pending = pendingRecording else { return }
        let format = videoFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "rec-\(timestamp()).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            guard let self else { return }
            guard result == .OK, let dest = panel.url else { return }
            Task { @MainActor in
                self.isExporting = true
                defer { self.isExporting = false }
                do {
                    try await self.export(from: pending.url, to: dest, format: format)
                    self.lastInfo = "Video guardado"
                } catch {
                    self.lastError = error.localizedDescription
                }
                try? FileManager.default.removeItem(at: pending.url)
                self.pendingRecording = nil
            }
        }
    }

    func copyPendingRecordingToClipboard() {
        guard let pending = pendingRecording else { return }
        let format = videoFormat
        Task { @MainActor in
            isExporting = true
            defer { isExporting = false }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("rec-\(timestamp()).\(format.fileExtension)")
            try? FileManager.default.removeItem(at: dest)
            do {
                try await export(from: pending.url, to: dest, format: format)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([dest as NSURL])
                lastInfo = "Video copiado al portapapeles"
            } catch {
                lastError = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: pending.url)
            pendingRecording = nil
        }
    }

    func discardPendingRecording() {
        guard let pending = pendingRecording else { return }
        try? FileManager.default.removeItem(at: pending.url)
        pendingRecording = nil
        lastInfo = "Grabación descartada"
    }

    private func export(from src: URL, to dest: URL, format: VideoFormat) async throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        let srcExt = src.pathExtension.lowercased()
        if format == .mov && srcExt == "mov" {
            try FileManager.default.copyItem(at: src, to: dest)
            return
        }
        try await transcode(from: src, to: dest, fileType: format.avFileType)
    }

    private func transcode(from src: URL, to dest: URL, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: src)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(
                domain: "CameraRecorder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No se pudo iniciar la exportación"]
            )
        }
        exporter.outputURL = dest
        exporter.outputFileType = fileType
        exporter.shouldOptimizeForNetworkUse = true
        let box = SendableBox(exporter)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.value.exportAsynchronously {
                switch box.value.status {
                case .completed:
                    cont.resume(returning: ())
                case .cancelled:
                    cont.resume(throwing: CancellationError())
                default:
                    cont.resume(throwing: box.value.error ?? NSError(
                        domain: "CameraRecorder",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Exportación fallida"]
                    ))
                }
            }
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in self.isRecording = true }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.isRecording = false
            self.recordingElapsed = 0
            self.recStart = nil
            if let error {
                let nsError = error as NSError
                let success = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
                if success {
                    self.pendingRecording = PendingRecording(url: outputFileURL)
                } else {
                    self.lastError = error.localizedDescription
                    try? FileManager.default.removeItem(at: outputFileURL)
                }
            } else {
                self.pendingRecording = PendingRecording(url: outputFileURL)
            }
        }
    }
}

struct PendingRecording: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let completion: (NSImage?) -> Void
    init(completion: @escaping (NSImage?) -> Void) { self.completion = completion }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = NSImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }
}
