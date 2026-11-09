import Carbon.HIToolbox
import KeyNavCore

/// Shortcuts registered with the system rather than read from the event tap. macOS still delivers these while a
/// password field holds Secure Input, when the tap sees no keys at all.
@MainActor
final class SystemHotKeys {
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x4B4E_4156)

    var isEmpty: Bool { hotKeys.isEmpty }

    /// Registers `code` with `modifiers` under `id`, replacing any shortcut already under that id.
    func register(_ id: UInt32, code: UInt16, modifiers: Modifiers, action: @escaping () -> Void) {
        installHandler()
        if let existing = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(existing) }
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), carbon, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        hotKeys[id] = ref
        actions[id] = action
    }

    func unregisterAll() {
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
        actions.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<SystemHotKeys>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == OSType(0x4B4E_4156) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
