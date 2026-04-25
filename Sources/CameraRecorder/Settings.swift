import Foundation
import AVFoundation

enum SettingsKey {
    static let favoriteDeviceID = "favoriteDeviceID"
    static let lastDeviceID = "lastDeviceID"
    static let includeAudio = "includeAudio"
    static let resolution = "resolution"
    static let frameRate = "frameRate"
    static let mirror = "mirror"
    static let autoStart = "autoStart"
    static let photoFormat = "photoFormat"
}

enum ResolutionPreset: String, CaseIterable, Identifiable {
    case auto, sd480, hd720, hd1080, uhd2160
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:    return "Auto"
        case .sd480:   return "640×480"
        case .hd720:   return "1280×720 (HD)"
        case .hd1080:  return "1920×1080 (FHD)"
        case .uhd2160: return "3840×2160 (4K)"
        }
    }
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .auto:    return .high
        case .sd480:   return .vga640x480
        case .hd720:   return .hd1280x720
        case .hd1080:  return .hd1920x1080
        case .uhd2160: return .hd4K3840x2160
        }
    }
}

enum FrameRatePreset: Int, CaseIterable, Identifiable {
    case auto = 0
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
    var id: Int { rawValue }
    var label: String { self == .auto ? "Auto" : "\(rawValue) fps" }
}

enum PhotoFormat: String, CaseIterable, Identifiable {
    case jpeg, png
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png:  return "PNG"
        }
    }
}
