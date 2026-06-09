import Foundation

/// Top-level error type for the Trace application.
///
/// Every fallible
/// operation surfaces errors as `TraceError`, categorized for telemetry
/// (local-only — see spec §18) and for user-facing presentation logic.
public enum TraceError: Error, Sendable, CustomStringConvertible {

    // Audio capture & processing
    case audioCaptureFailed(reason: String)
    case audioDeviceMissing(name: String)
    case audioFormatUnsupported(format: String)

    // Speech / ASR
    case asrModelMissing(engine: String, model: String)
    case asrInferenceFailed(engine: String, reason: String)
    case diarizationFailed(reason: String)

    // Model layer (LLM)
    case modelProviderFailed(provider: String, underlying: Error)
    case modelRouteUnresolved(taskClass: String)

    // Storage
    case storageFailed(reason: String)
    case migrationFailed(fromVersion: Int, toVersion: Int, reason: String)

    // Permissions
    case permissionDenied(kind: PermissionKind)

    // Network / cloud
    case networkFailed(provider: String, statusCode: Int?, reason: String)

    // User-config
    case configInvalid(field: String, reason: String)

    public enum PermissionKind: String, Sendable {
        case microphone
        case systemAudio
        case accessibility
        case speechRecognition
        case calendar
        case notifications
        case appleEvents
    }

    public enum Category: String, Sendable {
        case audio
        case speech
        case model
        case storage
        case permission
        case network
        case config
    }

    public enum RecoveryAction: Sendable, Equatable {
        case openSystemSettings(pane: String)
        case promptUserToReconnect
        case retryWithBackoff
        case none

        public static func == (lhs: RecoveryAction, rhs: RecoveryAction) -> Bool {
            switch (lhs, rhs) {
            case (.openSystemSettings(let a), .openSystemSettings(let b)): return a == b
            case (.promptUserToReconnect, .promptUserToReconnect): return true
            case (.retryWithBackoff, .retryWithBackoff): return true
            case (.none, .none): return true
            default: return false
            }
        }
    }

    public var category: Category {
        switch self {
        case .audioCaptureFailed, .audioDeviceMissing, .audioFormatUnsupported: return .audio
        case .asrModelMissing, .asrInferenceFailed, .diarizationFailed: return .speech
        case .modelProviderFailed, .modelRouteUnresolved: return .model
        case .storageFailed, .migrationFailed: return .storage
        case .permissionDenied: return .permission
        case .networkFailed: return .network
        case .configInvalid: return .config
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .permissionDenied, .audioDeviceMissing, .networkFailed: return true
        default: return false
        }
    }

    public var recoveryAction: RecoveryAction {
        switch self {
        case .permissionDenied(let kind):
            switch kind {
            case .microphone: return .openSystemSettings(pane: "Privacy_Microphone")
            // macOS 14.4+ merged audio capture into the "Screen & System Audio
            // Recording" pane (Privacy_ScreenCapture). The old Privacy_AudioCapture
            // URL no-ops on macOS 26.
            case .systemAudio: return .openSystemSettings(pane: "Privacy_ScreenCapture")
            case .accessibility: return .openSystemSettings(pane: "Privacy_Accessibility")
            case .speechRecognition: return .openSystemSettings(pane: "Privacy_SpeechRecognition")
            case .calendar: return .openSystemSettings(pane: "Privacy_Calendars")
            case .notifications: return .openSystemSettings(pane: "com.apple.preference.notifications")
            case .appleEvents: return .openSystemSettings(pane: "Privacy_AppleEvents")
            }
        case .audioDeviceMissing: return .promptUserToReconnect
        case .networkFailed: return .retryWithBackoff
        default: return .none
        }
    }

    public var description: String { localizedDescription }

    public var localizedDescription: String {
        switch self {
        case .audioCaptureFailed(let reason):
            return "Audio capture failed: \(reason)"
        case .audioDeviceMissing(let name):
            return "Audio device not found: \(name)"
        case .audioFormatUnsupported(let format):
            return "Audio format unsupported: \(format)"
        case .asrModelMissing(let engine, let model):
            return "ASR engine \(engine) is missing model \(model)"
        case .asrInferenceFailed(let engine, let reason):
            return "ASR (\(engine)) failed: \(reason)"
        case .diarizationFailed(let reason):
            return "Diarization failed: \(reason)"
        case .modelProviderFailed(let provider, let underlying):
            return "LLM provider \(provider) failed: \(underlying.localizedDescription)"
        case .modelRouteUnresolved(let taskClass):
            return "No model route configured for task: \(taskClass)"
        case .storageFailed(let reason):
            return "Storage error: \(reason)"
        case .migrationFailed(let from, let to, let reason):
            return "Schema migration \(from)→\(to) failed: \(reason)"
        case .permissionDenied(let kind):
            return "Permission denied: \(kind.rawValue)"
        case .networkFailed(let provider, let code, let reason):
            let codeStr = code.map { " (HTTP \($0))" } ?? ""
            return "Network error from \(provider)\(codeStr): \(reason)"
        case .configInvalid(let field, let reason):
            return "Invalid config (\(field)): \(reason)"
        }
    }
}
