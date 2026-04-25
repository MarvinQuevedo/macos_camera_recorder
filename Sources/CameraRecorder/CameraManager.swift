import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String?
    @Published var includeAudio: Bool = true
    @Published var isRunning: Bool = false
    @Published var isRecording: Bool = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var lastVideoURL: URL?
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

    override init() {
        super.init()
        session.sessionPreset = .high
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        refreshDevices()
    }

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
        if selectedDeviceID == nil || !devices.contains(where: { $0.uniqueID == selectedDeviceID }) {
            selectedDeviceID = devices.first?.uniqueID
        }
    }

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
    }

    private func configure(videoDevice: AVCaptureDevice) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

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

    // MARK: - Photo

    func capturePhoto(toClipboard: Bool) {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
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
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "captura-\(timestamp()).png"
        panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                self?.lastError = "No se pudo codificar la imagen"
                return
            }
            let ext = url.pathExtension.lowercased()
            let isJPEG = ext == "jpg" || ext == "jpeg"
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
                self?.lastInfo = "Imagen guardada"
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Video

    func startRecording() {
        guard !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(timestamp()).mov")
        try? FileManager.default.removeItem(at: url)

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

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

    func saveLastVideoAs() {
        guard let src = lastVideoURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.quickTimeMovie]
        panel.nameFieldStringValue = src.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            guard result == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
                self?.lastInfo = "Video guardado"
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func copyLastVideoToClipboard() {
        guard let url = lastVideoURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        lastInfo = "Video copiado al portapapeles"
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
                    self.lastVideoURL = outputFileURL
                    self.lastInfo = "Grabación finalizada"
                } else {
                    self.lastError = error.localizedDescription
                }
            } else {
                self.lastVideoURL = outputFileURL
                self.lastInfo = "Grabación finalizada"
            }
        }
    }
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
