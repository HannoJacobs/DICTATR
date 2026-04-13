import CoreAudio
import Foundation

enum AudioDeviceDiagnostics {
    static func currentRouteSnapshot() -> String {
        let defaultInputDevice = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutputDevice = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let builtInMicDevice = findBuiltInMicDevice()
        let defaultInput = describeDevice(defaultInputDevice)
        let defaultOutput = describeDevice(defaultOutputDevice)
        let builtInMic = describeDevice(builtInMicDevice)

        return [
            "defaultInput={\(defaultInput)}",
            "defaultOutput={\(defaultOutput)}",
            "builtInMic={\(builtInMic)}",
            inputSelectionSnapshot(defaultInput: defaultInputDevice, builtInMic: builtInMicDevice)
        ].joined(separator: " ")
    }

    static func availableDevicesSnapshot() -> String {
        let devices = allDevices()
        guard !devices.isEmpty else { return "none" }
        return devices.map { "{\(describeDevice($0))}" }.joined(separator: " ")
    }

    static func findBuiltInMicDevice() -> AudioDeviceID? {
        allDevices().first { device in
            transportType(for: device) == kAudioDeviceTransportTypeBuiltIn && channelCount(device, scope: kAudioObjectPropertyScopeInput) > 0
        }
    }

    static func defaultInputIsBluetooth() -> Bool {
        guard let device = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice),
              let transport = transportType(for: device) else {
            return false
        }

        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func defaultOutputIsBluetooth() -> Bool {
        guard let device = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice),
              let transport = transportType(for: device) else {
            return false
        }

        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func activeRouteInvolvesBluetooth() -> Bool {
        defaultInputIsBluetooth() || defaultOutputIsBluetooth()
    }

    static func inputSelectionSnapshot(defaultInput: AudioDeviceID? = nil, builtInMic: AudioDeviceID? = nil) -> String {
        let resolvedDefaultInput = defaultInput ?? defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let resolvedBuiltInMic = builtInMic ?? findBuiltInMicDevice()
        let defaultTransport = transportLabel(resolvedDefaultInput.flatMap(transportType(for:)))
        let builtInAvailable = resolvedBuiltInMic != nil
        let defaultIsBuiltInMic = resolvedDefaultInput != nil && resolvedDefaultInput == resolvedBuiltInMic

        return [
            "inputSelection={",
            "defaultInputIsBluetooth=\(AppDiagnostics.boolLabel(defaultInputIsBluetooth()))",
            "defaultOutputIsBluetooth=\(AppDiagnostics.boolLabel(defaultOutputIsBluetooth()))",
            "defaultInputTransport=\(defaultTransport)",
            "builtInMicAvailable=\(AppDiagnostics.boolLabel(builtInAvailable))",
            "defaultInputMatchesBuiltInMic=\(AppDiagnostics.boolLabel(defaultIsBuiltInMic))",
            "activeRouteInvolvesBluetooth=\(AppDiagnostics.boolLabel(activeRouteInvolvesBluetooth()))",
            "}"
        ].joined(separator: " ")
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else {
            return []
        }

        return devices
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private static func describeDevice(_ device: AudioDeviceID?) -> String {
        guard let device else { return "none" }

        let name = stringProperty(device, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "unknown"
        let uid = stringProperty(device, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) ?? "unknown"
        let sampleRate = doubleProperty(device, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        let transport = transportLabel(transportType(for: device))
        let inputChannels = channelCount(device, scope: kAudioObjectPropertyScopeInput)
        let outputChannels = channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        let alive = uint32Property(device, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)

        return [
            "id=\(device)",
            "name=\(name)",
            "uid=\(uid)",
            "transport=\(transport)",
            "nominalHz=\(sampleRate.map { String(format: "%.1f", $0) } ?? "unknown")",
            "in=\(inputChannels)",
            "out=\(outputChannels)",
            "alive=\(alive == nil ? "unknown" : (alive == 0 ? "no" : "yes"))"
        ].joined(separator: " ")
    }

    private static func transportType(for device: AudioDeviceID) -> UInt32? {
        uint32Property(device, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func transportLabel(_ value: UInt32?) -> String {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn:
            return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeAggregate:
            return "aggregate"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay"
        case kAudioDeviceTransportTypeVirtual:
            return "virtual"
        case .some(let raw):
            return "0x" + String(raw, radix: 16)
        case .none:
            return "unknown"
        }
    }

    private static func stringProperty(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let rawValue = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString?>.size,
            alignment: MemoryLayout<CFString?>.alignment
        )
        defer { rawValue.deallocate() }

        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, rawValue) == noErr else {
            return nil
        }

        let value = rawValue.assumingMemoryBound(to: CFString?.self).move()
        return value as String?
    }

    private static func doubleProperty(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func uint32Property(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, rawBuffer) == noErr else {
            return 0
        }

        let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }
}
