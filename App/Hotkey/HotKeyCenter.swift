import Carbon.HIToolbox

/// Minimal Carbon `RegisterEventHotKey` wrapper (no permission prompt, works unsandboxed and
/// sandboxed). Unlike most wrappers it hands back the `OSStatus`, so a failed registration
/// (e.g. `eventHotKeyExistsErr` −9878) can be shown to the user. Holds one hotkey per id (the
/// launcher, the clipboard history).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    /// While a Settings recorder listens for a new combo, no hotkey fires (the recorder swallows
    /// every key-down, so a panel opened then could not be typed in).
    var isPaused = false
    fileprivate static let signature: OSType = 0x4553_5243 // 'ESRC'

    private init() {}

    /// Replaces the registration under `id`. Returns the Carbon status (`noErr` on success).
    @discardableResult
    func register(_ combo: KeyCombo, id: UInt32, onPressed: @escaping () -> Void) -> OSStatus {
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return handlerStatus }
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            handlers[id] = onPressed
        }
        return status
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handlerRef)
    }

    fileprivate func handlePressed(_ hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == Self.signature, !isPaused else { return }
        handlers[hotKeyID.id]?()
    }

    static func describe(_ status: OSStatus) -> String {
        switch Int(status) {
        case eventHotKeyExistsErr: return "이미 다른 앱이 사용 중인 단축키입니다 (OSStatus \(status))"
        case eventHotKeyInvalidErr: return "유효하지 않은 단축키입니다 (OSStatus \(status))"
        default: return "단축키를 등록하지 못했습니다 (OSStatus \(status))"
        }
    }
}

/// Carbon delivers hot-key events on the main thread via the application event target.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let pressed = hotKeyID
    MainActor.assumeIsolated {
        HotKeyCenter.shared.handlePressed(pressed)
    }
    return noErr
}
