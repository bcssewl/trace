import AppKit
import Carbon.HIToolbox
import SharedCore
import SwiftUI

/// The five global actions the user can bind a hotkey to.
///
/// Raw values match
/// the IDs used in `AppRuntimeCoordinator.registerGlobalControls`.
public enum HotkeyAction: String, CaseIterable, Identifiable, Sendable {
    case dictationToggle = "dictation.toggle"
    case meetingToggle = "meeting.toggle"
    case voiceMemoToggle = "voiceMemo.toggle"
    case transcribeFile = "file.transcribe"
    case openLibrary = "library.open"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dictationToggle: return "Start or stop dictation"
        case .meetingToggle: return "Start or stop a meeting"
        case .voiceMemoToggle: return "Record a voice memo"
        case .transcribeFile: return "Transcribe a file"
        case .openLibrary: return "Open the main window"
        }
    }

    public var hint: String {
        switch self {
        case .dictationToggle: return "Tap to start and stop — your words appear where your cursor is"
        case .meetingToggle: return "Record your mic and the other people on the call"
        case .voiceMemoToggle: return "A quick, hands-free recording"
        case .transcribeFile: return "Choose an audio or video file to transcribe"
        case .openLibrary: return "Bring up the main Trace window"
        }
    }

    public var defaultDescriptor: HotkeyDescriptor {
        switch self {
        case .dictationToggle: return HotkeyDescriptor(keyCode: UInt32(kVK_Space), modifiers: [.option])
        case .meetingToggle: return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_M), modifiers: [.option])
        case .voiceMemoToggle: return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_V), modifiers: [.option])
        case .transcribeFile: return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_F), modifiers: [.option])
        case .openLibrary: return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_O), modifiers: [.command])
        }
    }
}

/// Human-readable rendering of a hotkey, e.g. "⌥ Space", "⌘ ⇧ ." Used by the
/// settings recorder and the keycap chips.
public enum HotkeyFormatter {
    public static func display(_ d: HotkeyDescriptor) -> String {
        if let tap = d.modifierTap {
            return tap.displayName
        }
        var parts: [String] = []
        if d.modifiers.contains(.control) { parts.append("⌃") }
        if d.modifiers.contains(.option) { parts.append("⌥") }
        if d.modifiers.contains(.shift) { parts.append("⇧") }
        if d.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyName(d.keyCode))
        return parts.joined(separator: " ")
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        default:
            if let mapped = letterDigitMap[Int(code)] { return mapped }
            return "Key \(code)"
        }
    }

    private static let letterDigitMap: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    /// Translate an AppKit modifier flag set into our descriptor modifiers.
    static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyDescriptor.Modifier> {
        var mods: Set<HotkeyDescriptor.Modifier> = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        return mods
    }
}

/// A button that, when clicked, listens for the next key combo and reports it.
///
/// Uses a local NSEvent monitor so it only captures while recording.
@MainActor
struct HotkeyRecorder: View {
    @Environment(\.brutalistPalette) private var palette
    /// Stable identity for this recorder, used to coordinate which recorder is
    /// armed.
    ///
    /// Only one recorder may listen at a time.
    let id: String
    let descriptor: HotkeyDescriptor
    /// The id of the recorder currently armed across the whole settings pane.
    ///
    /// Arming this recorder sets it; arming another clears us.
    @Binding var activeID: String?
    /// When true, a clean tap of a lone right-side modifier (⌘/⌥/⌃) records that
    /// key as the trigger. Pressing a modifier and then a key still records the
    /// full combo — the lone modifier is only committed on release with no key in
    /// between, so it never pre-empts a combo (the old bug that made ⌥+key
    /// impossible to record on the dictation row).
    var allowsModifierTap: Bool = false
    let onChange: (HotkeyDescriptor) -> Void

    @State private var monitor: Any?
    @State private var flagsMonitor: Any?
    /// A lone right-modifier seen pressed but not yet committed: held until release
    /// (clean tap → commit) or superseded by a key-down (combo wins).
    @State private var armedModifierTap: ModifierTapKey?

    private var recording: Bool { activeID == id }

    var body: some View {
        Button {
            toggleRecording()
        } label: {
            Text(recording ? "Press keys…" : HotkeyFormatter.display(descriptor))
                .font(BrutalistTypography.mono11)
                .foregroundStyle(recording ? palette.primary.color : palette.fg.color)
                .frame(minWidth: 96)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(recording ? palette.primary.color.opacity(0.12) : palette.secondary.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(recording ? palette.primary.color : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        // If another recorder becomes armed, tear our monitor down so only one
        // local key monitor is ever live at a time.
        .onChange(of: activeID) { _, newValue in
            if newValue != id { teardownMonitor() }
        }
        .onDisappear { stop() }
    }

    private func toggleRecording() {
        if recording {
            stop()
            return
        }
        // Arming this recorder clears any other (its .onChange tears it down).
        activeID = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotkeyFormatter.modifiers(from: event.modifierFlags)
            // Require at least one modifier so we don't bind a bare key that
            // would fire constantly during normal typing.
            guard !mods.isEmpty else { return nil }
            // A real key with modifiers is a full combo — it wins over any
            // lone-modifier we'd armed, so ⌥+key records ⌥+key, not just ⌥.
            armedModifierTap = nil
            onChange(HotkeyDescriptor(keyCode: UInt32(event.keyCode), modifiers: mods))
            stop()
            return nil  // swallow the event
        }
        if allowsModifierTap {
            // A lone right-side modifier is committed only on a *clean tap* (press
            // then release with no key in between). Arming on press — rather than
            // committing immediately — is what lets the modifier also begin a combo
            // (⌥+key), which the key-down monitor above then captures instead.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                if let down = ModifierTapKey.pressed(in: event) {
                    armedModifierTap = down
                    return nil
                }
                if let armed = armedModifierTap,
                    event.keyCode == armed.keyCode, !armed.isDown(in: event)
                {
                    armedModifierTap = nil
                    onChange(HotkeyDescriptor(modifierTap: armed))
                    stop()
                    return nil
                }
                return event
            }
        }
    }

    private func stop() {
        if activeID == id { activeID = nil }
        teardownMonitor()
    }

    private func teardownMonitor() {
        armedModifierTap = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }
}
