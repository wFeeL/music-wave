import AudioToolbox
import CoreAudio
import Foundation
import WaveCore

/// Устройство вывода по умолчанию: UID, имя, громкость, mute и задержка.
@MainActor
final class OutputDeviceMonitor {
    private(set) var deviceID: AudioObjectID = kAudioObjectUnknown
    private(set) var deviceUID = ""
    private(set) var deviceName = ""
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var latency = OutputLatency(
        deviceFrames: 0,
        streamFrames: 0,
        safetyOffsetFrames: 0,
        bufferFrames: 0,
        sampleRate: 0,
        isBluetooth: false
    )

    /// Сменилось устройство по умолчанию, его частота или перезапустился coreaudiod.
    var onDeviceChange: (() -> Void)?
    /// Изменилась громкость или mute.
    var onVolumeChange: (() -> Void)?

    /// Громкость, которую учитывает анализ: без звука она 0.
    var effectiveVolume: Float { isMuted ? 0 : volume }

    private var systemTokens: [CAListenerToken] = []
    private var deviceTokens: [CAListenerToken] = []

    init() {
        reloadDevice()
    }

    func start() {
        guard systemTokens.isEmpty else { return }
        reloadDevice()
        subscribeToDevice()
        systemTokens = [
            CAProperty.listen(CAProperty.systemObject, kAudioHardwarePropertyDefaultOutputDevice, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.defaultDeviceChanged() }
            },
            CAProperty.listen(CAProperty.systemObject, kAudioHardwarePropertyServiceRestarted, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.defaultDeviceChanged() }
            },
        ]
    }

    func stop() {
        for token in systemTokens + deviceTokens { token.cancel() }
        systemTokens = []
        deviceTokens = []
    }

    // MARK: - События

    private func defaultDeviceChanged() {
        reloadDevice()
        subscribeToDevice()
        onDeviceChange?()
    }

    private func formatChanged() {
        readLatency()
        onDeviceChange?()
    }

    private func volumeChanged() {
        readVolume()
        onVolumeChange?()
    }

    private func subscribeToDevice() {
        for token in deviceTokens { token.cancel() }
        deviceTokens = []
        let device = deviceID
        guard device != kAudioObjectUnknown else { return }

        let output = kAudioDevicePropertyScopeOutput
        if CAProperty.has(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: output) {
            deviceTokens.append(CAProperty.listen(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: output, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.volumeChanged() }
            })
        }
        if CAProperty.has(device, kAudioDevicePropertyMute, scope: output) {
            deviceTokens.append(CAProperty.listen(device, kAudioDevicePropertyMute, scope: output, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.volumeChanged() }
            })
        }
        deviceTokens.append(CAProperty.listen(device, kAudioDevicePropertyNominalSampleRate, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.formatChanged() }
        })
    }

    // MARK: - Чтение

    private func reloadDevice() {
        deviceID = CAProperty.read(CAProperty.systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: kAudioObjectUnknown)
        deviceUID = CAProperty.readCFString(deviceID, kAudioDevicePropertyDeviceUID) ?? ""
        deviceName = CAProperty.readCFString(deviceID, kAudioObjectPropertyName) ?? ""
        readVolume()
        readLatency()
    }

    private func readVolume() {
        let output = kAudioDevicePropertyScopeOutput
        if CAProperty.has(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: output) {
            let value: Float32 = CAProperty.read(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: output, default: 1)
            volume = value.isFinite ? min(max(value, 0), 1) : 1
        } else {
            volume = 1
        }
        let mute: UInt32 = CAProperty.read(deviceID, kAudioDevicePropertyMute, scope: output, default: 0)
        isMuted = mute != 0
    }

    private func readLatency() {
        let device = deviceID
        let output = kAudioDevicePropertyScopeOutput
        let deviceFrames: UInt32 = CAProperty.read(device, kAudioDevicePropertyLatency, scope: output, default: 0)
        let safetyOffset: UInt32 = CAProperty.read(device, kAudioDevicePropertySafetyOffset, scope: output, default: 0)
        let bufferFrames: UInt32 = CAProperty.read(device, kAudioDevicePropertyBufferFrameSize, default: 0)
        let streams: [AudioStreamID] = CAProperty.readArray(device, kAudioDevicePropertyStreams, scope: output)
        var streamFrames: UInt32 = 0
        if let stream = streams.first {
            streamFrames = CAProperty.read(stream, kAudioStreamPropertyLatency, default: 0)
        }
        let sampleRate: Float64 = CAProperty.read(device, kAudioDevicePropertyNominalSampleRate, default: 0)
        let transport: UInt32 = CAProperty.read(device, kAudioDevicePropertyTransportType, default: 0)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
        latency = OutputLatency(
            deviceFrames: deviceFrames,
            streamFrames: streamFrames,
            safetyOffsetFrames: safetyOffset,
            bufferFrames: bufferFrames,
            sampleRate: sampleRate.isFinite ? sampleRate : 0,
            isBluetooth: isBluetooth
        )
    }
}
