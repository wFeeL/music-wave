import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import WaveCore

enum TapStatus: Equatable, Sendable {
    case idle
    case running(sampleRate: Double, processCount: Int)
    case failed(String)
}

struct TapError: Error, CustomStringConvertible, Sendable {
    let message: String
    var description: String { message }
}

/// Захват звука процессов через Core Audio process tap и приватное агрегатное устройство.
///
/// Создание и удаление tap и агрегата идет на своей последовательной очереди (это IPC с coreaudiod),
/// публичные методы синхронно ждут ее. IOProc работает на очереди `tap-io` и пишет моно в кольцо.
nonisolated final class ProcessTapCapture: @unchecked Sendable {
    private struct Published: Sendable {
        var status: TapStatus
        var sampleRate: Double
    }

    private let mixer: MonoMixer
    private let controlQueue = DispatchQueue(label: "com.wfeels.wavefeels.tap-control")
    private let ioQueue = DispatchQueue(label: "com.wfeels.wavefeels.tap-io", qos: .userInteractive)
    private let published = Mutex(Published(status: .idle, sampleRate: 0))

    // Только на controlQueue.
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var procID: AudioDeviceIOProcID?

    init(ring: SampleRingBuffer) {
        mixer = MonoMixer(ring: ring)
    }

    var status: TapStatus { published.withLock { $0.status } }

    /// Частота сэмплов, которые IOProc пишет в кольцо; 0, пока tap не работает.
    var sampleRate: Double { published.withLock { $0.sampleRate } }

    /// Пересоздает tap и агрегат. При ошибке статус `failed`, все созданное удаляется.
    func start(processObjectIDs: [AudioObjectID], systemWide: Bool, outputDeviceUID: String) throws {
        try controlQueue.sync {
            try self.startOnControlQueue(
                processObjectIDs: processObjectIDs,
                systemWide: systemWide,
                outputDeviceUID: outputDeviceUID
            )
        }
    }

    func stop() {
        controlQueue.sync {
            let error = self.teardown()
            if let error {
                Self.log("остановка tap: \(error)")
                self.publish(.failed(error), sampleRate: 0)
            } else {
                self.publish(.idle, sampleRate: 0)
            }
        }
    }

    // MARK: - Очередь управления

    private func startOnControlQueue(processObjectIDs: [AudioObjectID], systemWide: Bool, outputDeviceUID: String) throws {
        if let error = teardown() {
            Self.log("остановка прошлого tap: \(error)")
        }
        do {
            let description = try Self.makeTapDescription(processObjectIDs: processObjectIDs, systemWide: systemWide)

            var newTap: AudioObjectID = kAudioObjectUnknown
            try Self.check(AudioHardwareCreateProcessTap(description, &newTap), "AudioHardwareCreateProcessTap")
            tapID = newTap
            let tapFormat: AudioStreamBasicDescription = CAProperty.read(
                newTap,
                kAudioTapPropertyFormat,
                default: AudioStreamBasicDescription()
            )

            let aggregate = Self.makeAggregateDescription(
                tapUUID: description.uuid.uuidString,
                outputDeviceUID: outputDeviceUID
            )
            var newAggregate: AudioObjectID = kAudioObjectUnknown
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate),
                "AudioHardwareCreateAggregateDevice"
            )
            aggregateID = newAggregate

            let layout = Self.inputLayout(aggregate: newAggregate, tapFormat: tapFormat)
            let rate = try Self.inputSampleRate(aggregate: newAggregate, layout: layout, tapFormat: tapFormat)

            var newProc: AudioDeviceIOProcID?
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, ioQueue, Self.makeIOBlock(mixer)),
                "AudioDeviceCreateIOProcIDWithBlock"
            )
            procID = newProc
            if let newProc {
                Self.enableOnlyTapStreams(aggregate: newAggregate, procID: newProc, layout: layout)
            }
            // IOProc еще не запущен: смена номера первого буфера tap не гоняется с аудиопотоком.
            mixer.setFirstTapBuffer(layout.firstTapStream)
            try Self.check(AudioDeviceStart(newAggregate, newProc), "AudioDeviceStart")

            let count = systemWide ? 0 : processObjectIDs.count
            publish(.running(sampleRate: rate, processCount: count), sampleRate: rate)
            Self.log("tap запущен: \(systemWide ? "весь звук" : "процессов \(count)"), \(Int(rate)) Гц, вывод \(outputDeviceUID)")
        } catch {
            let message = (error as? TapError)?.message ?? "\(error)"
            Self.log("tap не запущен: \(message)")
            _ = teardown()
            publish(.failed(message), sampleRate: 0)
            throw error
        }
    }

    /// Останавливает IOProc и удаляет агрегат и tap. Возвращает текст первой ошибки.
    private func teardown() -> String? {
        var firstError: String?
        func note(_ status: OSStatus, _ call: String) {
            if status != noErr, firstError == nil {
                firstError = "\(call): \(CAProperty.describe(status))"
            }
        }

        if aggregateID != kAudioObjectUnknown {
            if let procID {
                note(AudioDeviceStop(aggregateID, procID), "AudioDeviceStop")
                note(AudioDeviceDestroyIOProcID(aggregateID, procID), "AudioDeviceDestroyIOProcID")
                self.procID = nil
            }
            // Дождаться блоков, уже поставленных в очередь: в кольце не должно быть двух писателей.
            ioQueue.sync {}
            note(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = kAudioObjectUnknown
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            note(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = kAudioObjectUnknown
        }
        return firstError
    }

    private func publish(_ status: TapStatus, sampleRate: Double) {
        published.withLock { $0 = Published(status: status, sampleRate: sampleRate) }
    }

    // MARK: - Построение

    private static func makeTapDescription(processObjectIDs: [AudioObjectID], systemWide: Bool) throws -> CATapDescription {
        let description: CATapDescription
        if systemWide {
            let own: AudioObjectID = CAProperty.read(
                CAProperty.systemObject,
                kAudioHardwarePropertyTranslatePIDToProcessObject,
                qualifier: UInt32(bitPattern: getpid()),
                default: kAudioObjectUnknown
            )
            let excluded: [AudioObjectID] = own == kAudioObjectUnknown ? [] : [own]
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        } else {
            guard !processObjectIDs.isEmpty else {
                throw TapError(message: "нет процессов для захвата")
            }
            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "WaveFeels Tap"
        return description
    }

    private static func makeAggregateDescription(tapUUID: String, outputDeviceUID: String) -> [String: Any] {
        let tap: [String: Any] = [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapUUID,
        ]
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WaveFeels Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [tap],
        ]
        if !outputDeviceUID.isEmpty {
            let subDevice: [String: Any] = [kAudioSubDeviceUIDKey: outputDeviceUID]
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [subDevice]
        }
        return description
    }

    /// Входные потоки агрегата: сначала входы подустройства (микрофон AirPods или гарнитуры),
    /// за ними потоки tap. IOProc видит по буферу на каждый поток.
    private struct InputLayout {
        var streams: [AudioStreamID]
        var channels: [Int]
        var formats: [AudioStreamBasicDescription]
        /// Индекс первого потока tap; потоки tap идут до конца списка.
        var firstTapStream: Int

        var tapStreams: Range<Int> { firstTapStream..<max(firstTapStream, streams.count) }
    }

    /// Находит потоки tap: они идут после входных потоков подустройств. Сверяет число их каналов
    /// с форматом tap и пишет раскладку в лог (ее показывает диагностика).
    private static func inputLayout(aggregate: AudioObjectID, tapFormat: AudioStreamBasicDescription) -> InputLayout {
        let streams: [AudioStreamID] = CAProperty.readArray(
            aggregate,
            kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        let formats = streams.map { stream -> AudioStreamBasicDescription in
            CAProperty.read(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
        }
        let channels = formats.map { Int($0.mChannelsPerFrame) }

        let subDevices: [AudioObjectID] = CAProperty.readArray(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList)
        var subDeviceInputs = 0
        for device in subDevices {
            let inputs: [AudioStreamID] = CAProperty.readArray(
                device,
                kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeInput
            )
            subDeviceInputs += inputs.count
        }

        var first = subDeviceInputs
        if first >= streams.count {
            log("входных потоков агрегата \(streams.count), у подустройств \(subDeviceInputs): беру последний поток как tap")
            first = max(streams.count - 1, 0)
        }
        let tapChannels = Int(tapFormat.mChannelsPerFrame)
        let foundChannels = first < channels.count ? channels[first...].reduce(0, +) : 0
        if tapChannels > 0, foundChannels != tapChannels {
            log("каналов в потоках tap \(foundChannels), в формате tap \(tapChannels)")
        }

        let perStream = channels.enumerated()
            .map { index, count in "#\(index): \(count) кан.\(index >= first ? " tap" : "")" }
            .joined(separator: ", ")
        log("входных потоков агрегата \(streams.count) (у подустройств \(subDeviceInputs)): \(perStream)")
        return InputLayout(streams: streams, channels: channels, formats: formats, firstTapStream: first)
    }

    /// Включает для IOProc только потоки tap (`kAudioDevicePropertyIOProcStreamUsage`), чтобы
    /// микрофон подустройства не работал и Bluetooth-гарнитура не переходила в профиль звонка.
    /// Ошибка только пишется в лог: tap работает и без этого, `MonoMixer` все равно берет
    /// только буферы tap.
    private static func enableOnlyTapStreams(aggregate: AudioObjectID, procID: AudioDeviceIOProcID, layout: InputLayout) {
        let count = layout.streams.count
        guard count > 0 else { return }

        // Структура переменной длины: `mStreamIsOn` это первый элемент массива из `count` значений.
        typealias Usage = AudioHardwareIOProcStreamUsage
        let procOffset = MemoryLayout<Usage>.offset(of: \Usage.mIOProc) ?? 0
        let countOffset = MemoryLayout<Usage>.offset(of: \Usage.mNumberStreams) ?? MemoryLayout<UnsafeMutableRawPointer>.size
        let flagsOffset = MemoryLayout<Usage>.offset(of: \Usage.mStreamIsOn) ?? countOffset + MemoryLayout<UInt32>.size
        let byteCount = max(
            MemoryLayout<Usage>.size + (count - 1) * MemoryLayout<UInt32>.size,
            flagsOffset + count * MemoryLayout<UInt32>.size
        )
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Usage>.alignment)
        defer { raw.deallocate() }
        _ = raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        raw.storeBytes(of: procID, toByteOffset: procOffset, as: AudioDeviceIOProcID.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: countOffset, as: UInt32.self)
        let tapStreams = layout.tapStreams
        for index in 0..<count {
            let isOn: UInt32 = tapStreams.contains(index) ? 1 : 0
            raw.storeBytes(of: isOn, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var address = CAProperty.makeAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioDevicePropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(byteCount), raw)
        if status == noErr {
            log("IOProc получает только потоки tap: \(tapStreams.map { "#\($0)" }.joined(separator: ", ")) из \(count)")
        } else {
            log("kAudioDevicePropertyIOProcStreamUsage не применен: \(CAProperty.describe(status)), микрофон подустройства может работать")
        }
    }

    /// Частота входа агрегата. Проверяет, что поток tap это Float32, и сверяет его с форматом tap.
    private static func inputSampleRate(
        aggregate: AudioObjectID,
        layout: InputLayout,
        tapFormat: AudioStreamBasicDescription
    ) throws -> Double {
        var streamFormat = AudioStreamBasicDescription()
        if layout.firstTapStream < layout.formats.count {
            streamFormat = layout.formats[layout.firstTapStream]
        }
        let nominal: Float64 = CAProperty.read(aggregate, kAudioDevicePropertyNominalSampleRate, default: 0)

        let format = streamFormat.mFormatID != 0 ? streamFormat : tapFormat
        if format.mFormatID != 0 {
            let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32
            guard isFloat32 else {
                throw TapError(message: "формат входа не Float32: \(describe(format))")
            }
        } else {
            log("формат входа агрегата неизвестен, считаю Float32")
        }
        if tapFormat.mFormatID != 0, streamFormat.mFormatID != 0,
           tapFormat.mSampleRate != streamFormat.mSampleRate
            || tapFormat.mChannelsPerFrame != streamFormat.mChannelsPerFrame {
            log("формат tap \(describe(tapFormat)) отличается от входа агрегата \(describe(streamFormat))")
        }

        for candidate in [nominal, streamFormat.mSampleRate, tapFormat.mSampleRate] where candidate.isFinite && candidate > 0 {
            return candidate
        }
        log("частота агрегата неизвестна, считаю 48000 Гц")
        return 48_000
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        let layout = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "раздельные" : "чередование"
        return "\(CAProperty.fourCC(format.mFormatID)) \(Int(format.mSampleRate)) Гц, каналов \(format.mChannelsPerFrame), "
            + "\(format.mBitsPerChannel) бит, \(layout)"
    }

    /// Блок IOProc. Создается вне главного актора и ничего не захватывает, кроме `MonoMixer`.
    private static func makeIOBlock(_ mixer: MonoMixer) -> AudioDeviceIOBlock {
        { @Sendable (_, inputData, _, _, _) in
            mixer.process(inputData)
        }
    }

    private static func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else {
            throw TapError(message: "\(call): \(CAProperty.describe(status))")
        }
    }

    private static func log(_ message: String) {
        Log.audio.info("\(message, privacy: .public)")
        Log.file(message)
    }
}

/// Сводит вход IOProc в моно и пишет в кольцо. Работает в аудиопотоке: без выделений памяти,
/// блокировок и логирования. Буфер на 8192 кадра выделен заранее, длинные блоки обрезаются.
nonisolated final class MonoMixer: @unchecked Sendable {
    static let maxFrames = 8192

    private let ring: SampleRingBuffer
    private let scratch: UnsafeMutablePointer<Float>
    /// Индекс первого буфера tap во входе агрегата; буферы до него принадлежат подустройству.
    private let firstTapBuffer = Atomic<Int>(0)

    init(ring: SampleRingBuffer) {
        self.ring = ring
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        scratch.initialize(repeating: 0, count: Self.maxFrames)
    }

    deinit {
        scratch.deallocate()
    }

    /// Вызывать, пока IOProc не запущен.
    func setFirstTapBuffer(_ index: Int) {
        firstTapBuffer.store(max(0, index), ordering: .releasing)
    }

    /// Чередующиеся каналы (1 буфер, N каналов) и раздельные (N буферов по 1 каналу) Float32.
    /// Сводятся только буферы tap, начиная с `firstTapBuffer`; выключенные потоки приходят с `mData == nil`.
    func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let first = firstTapBuffer.load(ordering: .acquiring)
        guard first < buffers.count else { return }
        var frames = Self.maxFrames
        var channels = 0
        for index in first..<buffers.count {
            let buffer = buffers[index]
            let count = Int(buffer.mNumberChannels)
            guard count > 0, buffer.mData != nil else { continue }
            frames = min(frames, Int(buffer.mDataByteSize) / (count * MemoryLayout<Float>.size))
            channels += count
        }
        guard channels > 0, frames > 0 else { return }

        let out = scratch
        out.update(repeating: 0, count: frames)
        for index in first..<buffers.count {
            let buffer = buffers[index]
            let count = Int(buffer.mNumberChannels)
            guard count > 0, let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            if count == 1 {
                for frame in 0..<frames {
                    out[frame] += samples[frame]
                }
            } else {
                for frame in 0..<frames {
                    let base = frame * count
                    var sum: Float = 0
                    for channel in 0..<count {
                        sum += samples[base + channel]
                    }
                    out[frame] += sum
                }
            }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            out[frame] *= scale
        }
        ring.write(UnsafeBufferPointer(start: out, count: frames))
    }
}
