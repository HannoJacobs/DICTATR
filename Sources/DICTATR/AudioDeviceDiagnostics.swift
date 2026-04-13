import CoreAudio
import Foundation

enum AudioDeviceDiagnostics {
    struct RouteState: Equatable {
        struct DeviceIdentity: Equatable {
            let id: AudioDeviceID?
            let name: String
            let uid: String
            let transport: String
            let nominalHz: String
            let inputChannels: UInt32
            let outputChannels: UInt32
            let alive: String
            let inputSourceID: UInt32?
            let inputSourceName: String

            var snapshot: String {
                [
                    "id=\(id.map(String.init) ?? "none")",
                    "name=\(name)",
                    "uid=\(uid)",
                    "transport=\(transport)",
                    "nominalHz=\(nominalHz)",
                    "in=\(inputChannels)",
                    "out=\(outputChannels)",
                    "alive=\(alive)",
                    "inputSourceID=\(inputSourceID.map(String.init) ?? "unknown")",
                    "inputSource=\(inputSourceName)"
                ].joined(separator: " ")
            }
        }

        let defaultInput: DeviceIdentity
        let defaultOutput: DeviceIdentity
        let builtInMic: DeviceIdentity
        let defaultInputIsBluetooth: Bool
        let defaultOutputIsBluetooth: Bool
        let activeRouteInvolvesBluetooth: Bool
        let availableDeviceCount: Int

        var fingerprint: String {
            [
                "inID=\(defaultInput.id.map(String.init) ?? "none")",
                "inUID=\(defaultInput.uid)",
                "inSrc=\(defaultInput.inputSourceID.map(String.init) ?? "unknown")",
                "outID=\(defaultOutput.id.map(String.init) ?? "none")",
                "outUID=\(defaultOutput.uid)",
                "inTransport=\(defaultInput.transport)",
                "outTransport=\(defaultOutput.transport)",
                "inHz=\(defaultInput.nominalHz)",
                "outHz=\(defaultOutput.nominalHz)",
                "btIn=\(AppDiagnostics.boolLabel(defaultInputIsBluetooth))",
                "btOut=\(AppDiagnostics.boolLabel(defaultOutputIsBluetooth))",
                "btRoute=\(AppDiagnostics.boolLabel(activeRouteInvolvesBluetooth))",
                "deviceCount=\(availableDeviceCount)"
            ].joined(separator: "|")
        }

        var inputSelectionSnapshot: String {
            [
                "inputSelection={",
                "defaultInputIsBluetooth=\(AppDiagnostics.boolLabel(defaultInputIsBluetooth))",
                "defaultOutputIsBluetooth=\(AppDiagnostics.boolLabel(defaultOutputIsBluetooth))",
                "defaultInputTransport=\(defaultInput.transport)",
                "builtInMicAvailable=\(AppDiagnostics.boolLabel(builtInMic.id != nil))",
                "defaultInputMatchesBuiltInMic=\(AppDiagnostics.boolLabel(defaultInput.id != nil && defaultInput.id == builtInMic.id))",
                "activeRouteInvolvesBluetooth=\(AppDiagnostics.boolLabel(activeRouteInvolvesBluetooth))",
                "}"
            ].joined(separator: " ")
        }

        var routeSnapshot: String {
            [
                "defaultInput={\(defaultInput.snapshot)}",
                "defaultOutput={\(defaultOutput.snapshot)}",
                "builtInMic={\(builtInMic.snapshot)}",
                "routeFingerprint=\(fingerprint)",
                "bluetoothModeGuess=\(bluetoothModeAssessment.mode.rawValue)",
                "inputNominalHz=\(bluetoothModeAssessment.inputNominalHz)",
                "outputNominalHz=\(bluetoothModeAssessment.outputNominalHz)",
                "modeGuessConfidence=\(bluetoothModeAssessment.confidence)",
                "modeGuessReason=\(bluetoothModeAssessment.reason)",
                inputSelectionSnapshot
            ].joined(separator: " ")
        }

        var bluetoothModeAssessment: BluetoothModeAssessment {
            let inputNominalHz = defaultInput.nominalHz
            let outputNominalHz = defaultOutput.nominalHz
            let defaultInputMatchesBuiltIn = defaultInput.id != nil && defaultInput.id == builtInMic.id
            let outputHzValue = Double(outputNominalHz)
            let inputHzValue = Double(inputNominalHz)

            if !activeRouteInvolvesBluetooth {
                return BluetoothModeAssessment(
                    mode: .unknown,
                    outputNominalHz: outputNominalHz,
                    inputNominalHz: inputNominalHz,
                    confidence: "low",
                    reason: "active route does not involve bluetooth"
                )
            }

            if defaultInputIsBluetooth && defaultOutputIsBluetooth {
                if let outputHzValue, outputHzValue <= 24000.0 {
                    return BluetoothModeAssessment(
                        mode: .hfp,
                        outputNominalHz: outputNominalHz,
                        inputNominalHz: inputNominalHz,
                        confidence: "high",
                        reason: "bluetooth input active and bluetooth output collapsed to telephony rate"
                    )
                }

                if let outputHzValue, outputHzValue >= 44100.0 {
                    return BluetoothModeAssessment(
                        mode: .mixed,
                        outputNominalHz: outputNominalHz,
                        inputNominalHz: inputNominalHz,
                        confidence: "medium",
                        reason: "bluetooth input active while output is still at high-fidelity rate"
                    )
                }
            }

            if defaultOutputIsBluetooth && defaultInputMatchesBuiltIn {
                if let outputHzValue, outputHzValue >= 44100.0 {
                    return BluetoothModeAssessment(
                        mode: .a2dp,
                        outputNominalHz: outputNominalHz,
                        inputNominalHz: inputNominalHz,
                        confidence: "high",
                        reason: "bluetooth output active while built-in microphone remains selected"
                    )
                }
            }

            if let inputHzValue, let outputHzValue, inputHzValue <= 24000.0, outputHzValue <= 32000.0 {
                return BluetoothModeAssessment(
                    mode: .hfp,
                    outputNominalHz: outputNominalHz,
                    inputNominalHz: inputNominalHz,
                    confidence: "medium",
                    reason: "input and output are both at telephony-like rates"
                )
            }

            return BluetoothModeAssessment(
                mode: .mixed,
                outputNominalHz: outputNominalHz,
                inputNominalHz: inputNominalHz,
                confidence: "low",
                reason: "bluetooth route present but transport rates do not match a stable profile"
            )
        }
    }

    static func currentRouteState() -> RouteState {
        let devices = allDevices()
        let defaultInputDevice = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutputDevice = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let builtInMicDevice = findBuiltInMicDevice(in: devices)
        let defaultInput = deviceIdentity(defaultInputDevice)
        let defaultOutput = deviceIdentity(defaultOutputDevice)
        let builtInMic = deviceIdentity(builtInMicDevice)

        let defaultInputIsBluetooth = isBluetoothTransport(device: defaultInputDevice)
        let defaultOutputIsBluetooth = isBluetoothTransport(device: defaultOutputDevice)

        return RouteState(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            builtInMic: builtInMic,
            defaultInputIsBluetooth: defaultInputIsBluetooth,
            defaultOutputIsBluetooth: defaultOutputIsBluetooth,
            activeRouteInvolvesBluetooth: defaultInputIsBluetooth || defaultOutputIsBluetooth,
            availableDeviceCount: devices.count
        )
    }

    static func currentRouteSnapshot() -> String {
        currentRouteState().routeSnapshot
    }

    static func routeFingerprint() -> String {
        currentRouteState().fingerprint
    }

    static func activeInputSnapshot() -> String {
        currentRouteState().defaultInput.snapshot
    }

    static func activeOutputSnapshot() -> String {
        currentRouteState().defaultOutput.snapshot
    }

    static func availableDevicesSnapshot() -> String {
        let devices = allDevices()
        guard !devices.isEmpty else { return "none" }
        return devices.map { "{\(deviceIdentity($0).snapshot)}" }.joined(separator: " ")
    }

    static func aggregateDeviceIDsSnapshot() -> String {
        let devices = allDevices().filter { transportType(for: $0) == kAudioDeviceTransportTypeAggregate }
        guard !devices.isEmpty else { return "none" }
        return devices.map { device in
            let identity = deviceIdentity(device)
            return "\(identity.id.map(String.init) ?? "none"):\(identity.uid)"
        }.joined(separator: "|")
    }

    static func routeChangedFields(
        from oldState: RouteState?,
        to newState: RouteState,
        inventoryChanged: Bool = false
    ) -> [String] {
        guard let oldState else {
            return [
                "observerInitialized",
                "defaultInputChanged",
                "defaultOutputChanged",
                inventoryChanged ? "deviceInventoryChanged" : nil
            ].compactMap { $0 }
        }

        var changes: [String] = []
        if oldState.defaultInput.id != newState.defaultInput.id {
            changes.append("defaultInputChanged")
        }
        if oldState.defaultOutput.id != newState.defaultOutput.id {
            changes.append("defaultOutputChanged")
        }
        if oldState.defaultInput.uid != newState.defaultInput.uid {
            changes.append("defaultInputUIDChanged")
        }
        if oldState.defaultOutput.uid != newState.defaultOutput.uid {
            changes.append("defaultOutputUIDChanged")
        }
        if oldState.defaultInput.nominalHz != newState.defaultInput.nominalHz {
            changes.append("defaultInputSampleRateChanged")
        }
        if oldState.defaultOutput.nominalHz != newState.defaultOutput.nominalHz {
            changes.append("defaultOutputSampleRateChanged")
        }
        if oldState.defaultInput.inputSourceID != newState.defaultInput.inputSourceID {
            changes.append("defaultInputSourceChanged")
        }
        if oldState.defaultInputIsBluetooth != newState.defaultInputIsBluetooth {
            changes.append("defaultInputBluetoothChanged")
        }
        if oldState.defaultOutputIsBluetooth != newState.defaultOutputIsBluetooth {
            changes.append("defaultOutputBluetoothChanged")
        }
        if oldState.activeRouteInvolvesBluetooth != newState.activeRouteInvolvesBluetooth {
            changes.append("bluetoothInvolvementChanged")
        }
        if oldState.bluetoothModeAssessment.mode != newState.bluetoothModeAssessment.mode {
            changes.append("bluetoothModeChanged")
        }
        if inventoryChanged || oldState.availableDeviceCount != newState.availableDeviceCount {
            changes.append("deviceInventoryChanged")
        }
        return changes.isEmpty ? ["noEffectiveRouteChange"] : changes
    }

    static func routeTransitionSummary(
        from oldState: RouteState?,
        to newState: RouteState,
        inventoryChanged: Bool = false
    ) -> String {
        routeChangedFields(from: oldState, to: newState, inventoryChanged: inventoryChanged).joined(separator: ",")
    }

    static func findBuiltInMicDevice() -> AudioDeviceID? {
        findBuiltInMicDevice(in: allDevices())
    }

    static func defaultInputIsBluetooth() -> Bool {
        isBluetoothTransport(device: defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice))
    }

    static func defaultOutputIsBluetooth() -> Bool {
        isBluetoothTransport(device: defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice))
    }

    static func activeRouteInvolvesBluetooth() -> Bool {
        defaultInputIsBluetooth() || defaultOutputIsBluetooth()
    }

    static func inputSelectionSnapshot(defaultInput: AudioDeviceID? = nil, builtInMic: AudioDeviceID? = nil) -> String {
        let state = currentRouteState()
        if let defaultInput, let builtInMic {
            let defaultIdentity = deviceIdentity(defaultInput)
            let builtInIdentity = deviceIdentity(builtInMic)
            return RouteState(
                defaultInput: defaultIdentity,
                defaultOutput: state.defaultOutput,
                builtInMic: builtInIdentity,
                defaultInputIsBluetooth: isBluetoothTransport(device: defaultInput),
                defaultOutputIsBluetooth: state.defaultOutputIsBluetooth,
                activeRouteInvolvesBluetooth: isBluetoothTransport(device: defaultInput) || state.defaultOutputIsBluetooth,
                availableDeviceCount: state.availableDeviceCount
            ).inputSelectionSnapshot
        }
        return state.inputSelectionSnapshot
    }

    private static func findBuiltInMicDevice(in devices: [AudioDeviceID]) -> AudioDeviceID? {
        devices.first { device in
            transportType(for: device) == kAudioDeviceTransportTypeBuiltIn && channelCount(device, scope: kAudioObjectPropertyScopeInput) > 0
        }
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

    private static func deviceIdentity(_ device: AudioDeviceID?) -> RouteState.DeviceIdentity {
        guard let device else {
            return .init(
                id: nil,
                name: "none",
                uid: "none",
                transport: "none",
                nominalHz: "unknown",
                inputChannels: 0,
                outputChannels: 0,
                alive: "unknown",
                inputSourceID: nil,
                inputSourceName: "unknown"
            )
        }

        let name = stringProperty(device, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "unknown"
        let uid = stringProperty(device, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) ?? "unknown"
        let sampleRate = doubleProperty(device, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        let transport = transportLabel(transportType(for: device))
        let inputChannels = channelCount(device, scope: kAudioObjectPropertyScopeInput)
        let outputChannels = channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        let aliveValue = uint32Property(device, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)
        let inputSourceID = inputDataSourceID(device)
        let inputSourceName = inputDataSourceName(device, sourceID: inputSourceID) ?? "unknown"

        return .init(
            id: device,
            name: name,
            uid: uid,
            transport: transport,
            nominalHz: sampleRate.map { String(format: "%.1f", $0) } ?? "unknown",
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            alive: aliveValue == nil ? "unknown" : (aliveValue == 0 ? "no" : "yes"),
            inputSourceID: inputSourceID,
            inputSourceName: inputSourceName
        )
    }

    private static func isBluetoothTransport(device: AudioDeviceID?) -> Bool {
        guard let device, let transport = transportType(for: device) else {
            return false
        }

        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(for device: AudioDeviceID) -> UInt32? {
        uint32Property(device, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func inputDataSourceID(_ device: AudioDeviceID) -> UInt32? {
        uint32Property(device, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeInput)
    }

    private static func inputDataSourceName(_ device: AudioDeviceID, sourceID: UInt32?) -> String? {
        guard let sourceID else { return nil }

        var source = sourceID
        var cfName: Unmanaged<CFString>?
        var translation = withUnsafeMutablePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &cfName) { namePointer in
                AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourcePointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePointer),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
            }
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation) == noErr,
              let unmanagedName = cfName else {
            return nil
        }

        return unmanagedName.takeRetainedValue() as String
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
