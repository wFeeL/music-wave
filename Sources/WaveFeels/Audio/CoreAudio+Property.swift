import CoreAudio
import Foundation
import Synchronization

/// Чтение свойств объектов Core Audio и подписка на их изменения.
///
/// Не привязан к актору: блоки для Core Audio создаются только здесь, в неизолированных
/// функциях, и помечены `@Sendable`, поэтому Swift 6 не вставляет в них проверку главного актора.
nonisolated enum CAProperty {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func makeAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func has(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        guard object != kAudioObjectUnknown else { return false }
        var address = makeAddress(selector, scope: scope)
        return AudioObjectHasProperty(object, &address)
    }

    /// Значение фиксированного размера. При ошибке или неожиданном размере возвращает `default`.
    static func read<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        qualifier: UInt32? = nil,
        default defaultValue: T
    ) -> T {
        guard object != kAudioObjectUnknown else { return defaultValue }
        var address = makeAddress(selector, scope: scope)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status: OSStatus
        if let qualifierValue = qualifier {
            let qualifierSize = UInt32(MemoryLayout<UInt32>.size)
            status = withUnsafeMutablePointer(to: &value) { valuePointer in
                withUnsafePointer(to: qualifierValue) { qualifierPointer in
                    AudioObjectGetPropertyData(object, &address, qualifierSize, qualifierPointer, &size, valuePointer)
                }
            }
        } else {
            status = withUnsafeMutablePointer(to: &value) { valuePointer in
                AudioObjectGetPropertyData(object, &address, 0, nil, &size, valuePointer)
            }
        }
        guard status == noErr, size == UInt32(MemoryLayout<T>.size) else { return defaultValue }
        return value
    }

    /// Массив значений фиксированного размера. При ошибке возвращает пустой массив.
    static func readArray<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [T] {
        readArrayIfReadable(object, selector, scope: scope) ?? []
    }

    /// Как `readArray`, но ошибка чтения дает `nil`, а не пустой массив: так пустой список
    /// отличается от непрочитанного.
    static func readArrayIfReadable<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [T]? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = makeAddress(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let stride = MemoryLayout<T>.stride
        let capacity = Int(size) / stride
        guard capacity > 0 else { return [] }
        var failed = false
        let values = [T](unsafeUninitializedCapacity: capacity) { buffer, initializedCount in
            initializedCount = 0
            guard let base = buffer.baseAddress else {
                failed = true
                return
            }
            var ioSize = UInt32(capacity * stride)
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &ioSize, base)
            if status == noErr {
                initializedCount = min(capacity, Int(ioSize) / stride)
            } else {
                failed = true
            }
        }
        return failed ? nil : values
    }

    /// Строковое свойство. Core Audio отдает строку с +1, поэтому `takeRetainedValue()`.
    static func readCFString(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = makeAddress(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, valuePointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Подписка на изменение свойства. `handler` вызывается на `queue`.
    /// Если подписаться не удалось, возвращается неактивный жетон.
    static func listen(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        _ handler: @escaping @Sendable () -> Void
    ) -> CAListenerToken {
        let block: AudioObjectPropertyListenerBlock = { @Sendable (_, _) in
            handler()
        }
        var address = makeAddress(selector, scope: scope)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status != noErr {
            let message = "подписка на \(fourCC(selector)) объекта \(object) не удалась: \(describe(status))"
            Log.audio.error("\(message, privacy: .public)")
        }
        return CAListenerToken(
            object: object,
            address: address,
            queue: queue,
            block: block,
            isActive: status == noErr
        )
    }

    /// Код ошибки в четырехсимвольном виде, если он печатается, и числом.
    static func describe(_ status: OSStatus) -> String {
        let code = fourCC(UInt32(bitPattern: status))
        return code.isEmpty ? "\(status)" : "'\(code)' (\(status))"
    }

    /// Четыре символа кода или пустая строка, если байты не печатаются.
    static func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Жетон подписки на свойство. Хранит тот же блок, что был передан в
/// `AudioObjectAddPropertyListenerBlock`: Core Audio снимает подписку только по нему.
nonisolated final class CAListenerToken: @unchecked Sendable {
    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let active: Mutex<Bool>

    fileprivate init(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock,
        isActive: Bool
    ) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
        self.active = Mutex(isActive)
    }

    /// Класс не привязан к актору, поэтому отписка в `deinit` безопасна.
    deinit {
        cancel()
    }

    /// Снимает подписку. Повторный вызов ничего не делает.
    func cancel() {
        let wasActive = active.withLock { value -> Bool in
            let previous = value
            value = false
            return previous
        }
        guard wasActive else { return }
        var address = self.address
        let status = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        if status != noErr {
            let message = "отписка от \(CAProperty.fourCC(address.mSelector)) не удалась: \(CAProperty.describe(status))"
            Log.audio.error("\(message, privacy: .public)")
        }
    }
}
