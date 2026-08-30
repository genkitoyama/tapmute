import Foundation
import CoreAudio

/// Thin wrappers over the CoreAudio device list and the system default devices.
/// Shared by MicMonitor (is anything capturing?) and AudioDeviceSwitcher (pick a device).
/// None of this needs a permission: no audio is touched, only device properties.
enum AudioDevices {

    struct Device {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let inputChannels: Int
        let outputChannels: Int

        var hasInput: Bool { inputChannels > 0 }
        var hasOutput: Bool { outputChannels > 0 }
    }

    // MARK: - Enumeration

    static func all() -> [Device] {
        ids().compactMap { id in
            let input = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let output = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard input > 0 || output > 0 else { return nil }
            return Device(id: id,
                          name: string(id, kAudioObjectPropertyName) ?? "(unnamed)",
                          uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                          inputChannels: input,
                          outputChannels: output)
        }
    }

    private static func ids() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        var result = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &result) == noErr
        else { return [] }
        return result
    }

    private static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        // CoreAudio hands back a +1 retained CFString here, so it is received as Unmanaged
        // and released by us. Reading into a plain CFString variable leaks it.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?
        else { return nil }
        return string.isEmpty ? nil : string
    }

    // MARK: - Activity

    /// Whether anything is currently running the device. Used as a hint that a call is in progress.
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: - System defaults

    enum Role {
        case input
        case output
        /// Alerts and sound effects. macOS tracks this separately from the main output.
        case systemOutput

        var selector: AudioObjectPropertySelector {
            switch self {
            case .input: return kAudioHardwarePropertyDefaultInputDevice
            case .output: return kAudioHardwarePropertyDefaultOutputDevice
            case .systemOutput: return kAudioHardwarePropertyDefaultSystemOutputDevice
            }
        }
    }

    static func defaultDevice(_ role: Role) -> AudioDeviceID? {
        var address = globalAddress(role.selector)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        return device
    }

    @discardableResult
    static func setDefault(_ device: AudioDeviceID, role: Role) -> Bool {
        var address = globalAddress(role.selector)
        var value = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value) == noErr
    }

    // MARK: - Change notification

    /// Calls the block whenever a device is plugged in or removed.
    /// Returns the listener block so it can be removed again.
    static func observeDeviceList(on queue: DispatchQueue,
                                  _ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        return block
    }

    static func removeDeviceListObserver(_ block: @escaping AudioObjectPropertyListenerBlock,
                                         on queue: DispatchQueue) {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
