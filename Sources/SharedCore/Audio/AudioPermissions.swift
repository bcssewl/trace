@preconcurrency import AVFoundation
import Foundation
import os

public enum AudioPermissions {

    public enum Status: Sendable, Equatable {
        case notDetermined
        case granted
        case denied
        case restricted
    }

    public static func mapStatus(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public static func currentMicStatus() -> Status {
        mapStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public static func requestMicrophoneAccess() async -> Status {
        if case .granted = currentMicStatus() {
            return .granted
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        let status: Status = granted ? .granted : .denied
        Loggers.audio.info("Mic permission request → \(String(describing: status), privacy: .public)")
        return status
    }

    public static func ensureMicAccess() async throws {
        let s = await requestMicrophoneAccess()
        guard s == .granted else {
            throw TraceError.permissionDenied(kind: .microphone)
        }
    }
}
