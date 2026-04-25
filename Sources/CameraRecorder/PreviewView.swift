import SwiftUI
import AVFoundation
import AppKit

struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let mirror: Bool

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.attach(session: session)
        view.setMirrored(mirror)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.attach(session: session)
        nsView.setMirrored(mirror)
    }
}

final class PreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
    }

    func setMirrored(_ mirrored: Bool) {
        guard let conn = previewLayer.connection, conn.isVideoMirroringSupported else { return }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = mirrored
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
