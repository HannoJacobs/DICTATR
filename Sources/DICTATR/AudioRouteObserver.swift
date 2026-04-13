import CoreAudio
import Foundation

@MainActor
final class AudioRouteObserver {
    private enum ObservedProperty: String {
        case defaultInput = "defaultInput"
        case defaultOutput = "defaultOutput"
        case deviceInventory = "deviceInventory"
        case inputNominalSampleRate = "inputNominalSampleRate"
        case outputNominalSampleRate = "outputNominalSampleRate"
    }

    private var currentRouteState = AudioDeviceDiagnostics.currentRouteState()
    private var observedInputDeviceID: AudioDeviceID?
    private var observedOutputDeviceID: AudioDeviceID?
    private var listenersInstalled = false

    init() {
        installSystemListeners()
        refreshObservedDeviceListeners()
        AppDiagnostics.info(
            .audioDevices,
            "audio route observer started routeFingerprint=\(currentRouteState.fingerprint) route=\(currentRouteState.routeSnapshot) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
    }

    private func installSystemListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true

        addSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice)
        addSystemListener(selector: kAudioHardwarePropertyDefaultOutputDevice)
        addSystemListener(selector: kAudioHardwarePropertyDevices)
    }

    private func removeSystemListeners() {
        guard listenersInstalled else { return }
        listenersInstalled = false

        removeSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice)
        removeSystemListener(selector: kAudioHardwarePropertyDefaultOutputDevice)
        removeSystemListener(selector: kAudioHardwarePropertyDevices)
    }

    private func addSystemListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioRouteObserverPropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status != noErr {
            AppDiagnostics.error(.audioDevices, "failed to install system route listener selector=\(selector) status=\(status)")
        }
    }

    private func removeSystemListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioRouteObserverPropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status != noErr {
            AppDiagnostics.warning(.audioDevices, "failed to remove system route listener selector=\(selector) status=\(status)")
        }
    }

    private func refreshObservedDeviceListeners() {
        let newState = AudioDeviceDiagnostics.currentRouteState()
        let newInputID = newState.defaultInput.id
        let newOutputID = newState.defaultOutput.id

        if observedInputDeviceID != newInputID {
            if let observedInputDeviceID {
                removeDeviceSampleRateListener(deviceID: observedInputDeviceID, label: .inputNominalSampleRate)
            }
            observedInputDeviceID = newInputID
            if let newInputID {
                addDeviceSampleRateListener(deviceID: newInputID, label: .inputNominalSampleRate)
            }
        }

        if observedOutputDeviceID != newOutputID {
            if let observedOutputDeviceID {
                removeDeviceSampleRateListener(deviceID: observedOutputDeviceID, label: .outputNominalSampleRate)
            }
            observedOutputDeviceID = newOutputID
            if let newOutputID {
                addDeviceSampleRateListener(deviceID: newOutputID, label: .outputNominalSampleRate)
            }
        }
    }

    private func removeObservedDeviceListeners() {
        if let observedInputDeviceID {
            removeDeviceSampleRateListener(deviceID: observedInputDeviceID, label: .inputNominalSampleRate)
            self.observedInputDeviceID = nil
        }

        if let observedOutputDeviceID {
            removeDeviceSampleRateListener(deviceID: observedOutputDeviceID, label: .outputNominalSampleRate)
            self.observedOutputDeviceID = nil
        }
    }

    private func addDeviceSampleRateListener(deviceID: AudioDeviceID, label: ObservedProperty) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            deviceID,
            &address,
            audioRouteObserverPropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status != noErr {
            AppDiagnostics.error(.audioDevices, "failed to install device listener property=\(label.rawValue) deviceID=\(deviceID) status=\(status)")
        }
    }

    private func removeDeviceSampleRateListener(deviceID: AudioDeviceID, label: ObservedProperty) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListener(
            deviceID,
            &address,
            audioRouteObserverPropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status != noErr {
            AppDiagnostics.warning(.audioDevices, "failed to remove device listener property=\(label.rawValue) deviceID=\(deviceID) status=\(status)")
        }
    }

    fileprivate func handlePropertyChange(objectID: AudioObjectID, selector: AudioObjectPropertySelector) {
        let trigger: ObservedProperty
        let includeDevices: Bool
        let inventoryChanged: Bool

        if objectID == AudioObjectID(kAudioObjectSystemObject) {
            switch selector {
            case kAudioHardwarePropertyDefaultInputDevice:
                trigger = .defaultInput
                includeDevices = false
                inventoryChanged = false
            case kAudioHardwarePropertyDefaultOutputDevice:
                trigger = .defaultOutput
                includeDevices = false
                inventoryChanged = false
            case kAudioHardwarePropertyDevices:
                trigger = .deviceInventory
                includeDevices = true
                inventoryChanged = true
            default:
                trigger = .deviceInventory
                includeDevices = false
                inventoryChanged = false
            }
        } else if objectID == observedInputDeviceID {
            trigger = .inputNominalSampleRate
            includeDevices = false
            inventoryChanged = false
        } else if objectID == observedOutputDeviceID {
            trigger = .outputNominalSampleRate
            includeDevices = false
            inventoryChanged = false
        } else {
            AppDiagnostics.debug(.audioDevices, "audio route observer ignored property change objectID=\(objectID) selector=\(selector)")
            return
        }

        logTransition(trigger: trigger.rawValue, inventoryChanged: inventoryChanged, includeDevices: includeDevices)
    }

    private func logTransition(trigger: String, inventoryChanged: Bool, includeDevices: Bool) {
        let previousState = currentRouteState
        let newState = AudioDeviceDiagnostics.currentRouteState()
        currentRouteState = newState
        refreshObservedDeviceListeners()

        let transition = AudioDeviceDiagnostics.routeTransitionSummary(
            from: previousState,
            to: newState,
            inventoryChanged: inventoryChanged
        )

        let message =
            "audio route observer trigger=\(trigger) transition=\(transition) previousFingerprint=\(previousState.fingerprint) currentFingerprint=\(newState.fingerprint) previousInput={\(previousState.defaultInput.snapshot)} currentInput={\(newState.defaultInput.snapshot)} previousOutput={\(previousState.defaultOutput.snapshot)} currentOutput={\(newState.defaultOutput.snapshot)} route=\(newState.routeSnapshot)"

        if includeDevices {
            AppDiagnostics.info(.audioDevices, "\(message) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())")
        } else {
            AppDiagnostics.info(.audioDevices, message)
        }
    }
}

private let audioRouteObserverPropertyListener: AudioObjectPropertyListenerProc = { objectID, numberAddresses, addresses, clientData in
    guard let clientData else { return noErr }
    let observer = Unmanaged<AudioRouteObserver>.fromOpaque(clientData).takeUnretainedValue()
    let addressBuffer = UnsafeBufferPointer(start: addresses, count: Int(numberAddresses))

    for address in addressBuffer {
        Task { @MainActor in
            observer.handlePropertyChange(objectID: objectID, selector: address.mSelector)
        }
    }

    return noErr
}
