import Carbon
import Foundation

public struct HotkeyID: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct HotkeyDescriptor: Sendable, Codable, Hashable {
    public enum Modifier: String, Sendable, Codable, Hashable { case command, option, control, shift }
    public let keyCode: UInt32
    public let modifiers: Set<Modifier>
    /// When set, this binding is a lone modifier-key (push-to-talk) trigger —
    /// `keyCode`/`modifiers` are ignored and it cannot be registered via Carbon;
    /// the runtime watches it with a `flagsChanged` monitor instead.
    ///
    /// Decodes to `nil` for older stored bindings that predate this field.
    public let modifierTap: ModifierTapKey?

    public init(keyCode: UInt32, modifiers: Set<Modifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.modifierTap = nil
    }

    /// A lone modifier-key trigger (e.g. hold right ⌘).
    public init(modifierTap: ModifierTapKey) {
        self.keyCode = 0
        self.modifiers = []
        self.modifierTap = modifierTap
    }

    /// True when this binding is a lone modifier-key trigger rather than a
    /// regular key+modifier combo.
    public var isModifierTap: Bool { modifierTap != nil }
}

public protocol CarbonHotkeyRegistering: Sendable {
    func register(id: HotkeyID, descriptor: HotkeyDescriptor) throws
    func unregister(id: HotkeyID)
}

public actor GlobalHotkeyCenter {
    public typealias Handler = @Sendable () -> Void
    private let registrar: any CarbonHotkeyRegistering
    private var handlers: [HotkeyID: Handler] = [:]

    public init(registrar: any CarbonHotkeyRegistering = CarbonHotkeyRegistrar()) {
        self.registrar = registrar
    }

    public func register(id: HotkeyID, descriptor: HotkeyDescriptor, handler: @escaping Handler) throws {
        try registrar.register(id: id, descriptor: descriptor)
        handlers[id] = handler
    }

    public func unregister(id: HotkeyID) {
        handlers[id] = nil
        registrar.unregister(id: id)
    }

    public func handleCarbonEvent(id: HotkeyID) {
        handlers[id]?()
    }
}

public final class CarbonHotkeyRegistrar: CarbonHotkeyRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var refs: [HotkeyID: EventHotKeyRef] = [:]
    private var carbonIDs: [HotkeyID: UInt32] = [:]
    private var hotkeyIDs: [UInt32: HotkeyID] = [:]
    private var nextCarbonID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?
    private var onPressed: (@Sendable (HotkeyID) -> Void)?
    public init() {}

    public func setEventHandler(_ handler: @escaping @Sendable (HotkeyID) -> Void) {
        lock.withLock { onPressed = handler }
    }

    public func register(id: HotkeyID, descriptor: HotkeyDescriptor) throws {
        try installEventHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let carbonID = lock.withLock { () -> UInt32 in
            let value = nextCarbonID
            nextCarbonID += 1
            carbonIDs[id] = value
            hotkeyIDs[value] = id
            return value
        }
        let hotkeyID = EventHotKeyID(signature: OSType(0x5350_4b48), id: carbonID)
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            lock.withLock {
                carbonIDs[id] = nil
                hotkeyIDs[carbonID] = nil
            }
            throw TraceError.configInvalid(field: "hotkey", reason: "RegisterEventHotKey failed: \(status)")
        }
        lock.withLock { refs[id] = ref }
    }

    public func unregister(id: HotkeyID) {
        let removed = lock.withLock { () -> EventHotKeyRef? in
            let ref = refs.removeValue(forKey: id)
            if let carbonID = carbonIDs.removeValue(forKey: id) {
                hotkeyIDs[carbonID] = nil
            }
            return ref
        }
        if let ref = removed {
            UnregisterEventHotKey(ref)
        }
    }

    private func installEventHandlerIfNeeded() throws {
        let shouldInstall = lock.withLock { eventHandlerRef == nil }
        guard shouldInstall else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotkeyID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard readStatus == noErr else { return readStatus }
                let registrar = Unmanaged<CarbonHotkeyRegistrar>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                registrar.dispatch(carbonID: hotkeyID.id)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        guard status == noErr, let ref else {
            throw TraceError.configInvalid(field: "hotkey", reason: "InstallEventHandler failed: \(status)")
        }
        lock.withLock { eventHandlerRef = ref }
    }

    private func dispatch(carbonID: UInt32) {
        let payload = lock.withLock { () -> (HotkeyID, (@Sendable (HotkeyID) -> Void))? in
            guard let id = hotkeyIDs[carbonID], let onPressed else { return nil }
            return (id, onPressed)
        }
        if let payload {
            payload.1(payload.0)
        }
    }
}

extension HotkeyDescriptor {
    fileprivate var carbonModifiers: UInt32 {
        modifiers.reduce(UInt32(0)) { out, modifier in
            switch modifier {
            case .command: return out | UInt32(cmdKey)
            case .option: return out | UInt32(optionKey)
            case .control: return out | UInt32(controlKey)
            case .shift: return out | UInt32(shiftKey)
            }
        }
    }
}
