#if os(macOS)
import Foundation
import CoreAudio

/// CoreAudio supplies macOS route changes; AVAudioSession notifications exist
/// only on iOS. Keep the observer alive alongside the other session observers.
final class MacAudioRoutes: NSObject, @unchecked Sendable {
    struct Snapshot { let device: AudioDeviceID; let name: String; let kind: String }
    private let queue = DispatchQueue(label: "BitChord.audio-route")
    private var previousDevice: AudioDeviceID
    private var listener: AudioObjectPropertyListenerBlock?
    private let changed: () -> Void
    private let disconnected: (() -> Void)?

    init(changed: @escaping () -> Void, disconnected: (() -> Void)?) {
        self.changed = changed; self.disconnected = disconnected
        previousDevice = Self.current().device
        super.init()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.routeChanged() }
        self.listener = listener
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            if status != noErr { PlaybackDebugLog.shared.record("CoreAudio route observer unavailable: \(status)") }
        }
    }
    deinit {
        guard let listener else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }
    private func routeChanged() {
        let current = Self.current()
        guard current.device != previousDevice else { return }
        let old = previousDevice
        previousDevice = current.device
        // Choosing another still-connected output is an ordinary route change.
        // Only a device that disappeared invalidates the listener's play intent.
        if old != 0, Self.integer(old, kAudioDevicePropertyDeviceIsAlive) != 1 { disconnected?() }
        changed()
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector); var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: UnsafeMutableRawPointer?
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        // CoreAudio returns an owned CFObject for kAudioObjectPropertyName.
        // Receive its pointer without writing through a Swift object reference.
        return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
    }
    static func current() -> Snapshot {
        let device = integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        let transport = integer(device, kAudioDevicePropertyTransportType)
        let kind: String
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "Bluetooth"
        case kAudioDeviceTransportTypeUSB: kind = "USB"
        case kAudioDeviceTransportTypeBuiltIn: kind = "Built-in"
        case kAudioDeviceTransportTypeAirPlay: kind = "AirPlay"
        default: kind = "System"
        }
        return Snapshot(device: device, name: string(device, kAudioObjectPropertyName) ?? "System output", kind: kind)
    }
}
#endif
