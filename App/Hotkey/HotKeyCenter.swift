import Carbon.HIToolbox

/// Minimal Carbon `RegisterEventHotKey` wrapper (no permission prompt, works unsandboxed and
/// sandboxed). Unlike most wrappers it hands back the `OSStatus`, so a failed registration
/// (e.g. `eventHotKeyExistsErr` −9878) can be shown to the user.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onPressed: (() -> Void)?
    private(set) var registeredCombo: KeyCombo?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate static let signature: OSType = 0x4553_5243 // 'ESRC'

    private init() {}

    /// Replaces any current registration. Returns the Carbon status (`noErr` on success).
    @discardableResult
    func register(_ combo: KeyCombo) -> OSStatus {
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return handlerStatus }
        unregister()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registeredCombo = combo
        }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registeredCombo = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handlerRef)
    }

    fileprivate func handlePressed(_ hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == Self.signature else { return }
        onPressed?()
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
