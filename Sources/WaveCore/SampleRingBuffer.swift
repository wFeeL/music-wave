import Synchronization

/// Метка блока сэмплов: номер первого сэмпла блока с момента создания или `reset()` кольца
/// и время хоста этого блока в тиках, как его дал аудио-колбэк.
public struct RingStamp: Sendable, Equatable {
    public var sampleIndex: Int
    public var hostTicks: UInt64

    public init(sampleIndex: Int, hostTicks: UInt64) {
        self.sampleIndex = sampleIndex
        self.hostTicks = hostTicks
    }
}

/// Кольцевой буфер сэмплов для одного писателя и одного читателя (SPSC).
///
/// Писатель (аудио-колбэк) вызывает `write` без блокировок и выделений памяти.
/// Читатель (таймер анализа) вызывает `copyWindow` или `copyLatest` по схеме seqlock: копирует
/// окно и проверяет, что писатель не успел его перезаписать. Метку последнего блока
/// (`latestStamp()`) писатель публикует через отдельный seqlock из атомиков, поэтому номер
/// сэмпла и время читаются согласованной парой.
public final class SampleRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let _capacity: Int
    /// Сколько сэмплов писатель уже опубликовал (данные доступны читателю).
    private let written = Atomic<Int>(0)
    /// Сколько сэмплов писатель успел заявить: растет до начала копирования,
    /// чтобы читатель увидел перезапись окна, которая еще не опубликована.
    private let claimed = Atomic<Int>(0)
    /// Seqlock метки: нечетный номер, пока писатель меняет пару. `stampIndex < 0` значит,
    /// что метки нет.
    private let stampSequence = Atomic<UInt64>(0)
    private let stampIndex = Atomic<Int>(-1)
    private let stampTicks = Atomic<UInt64>(0)
    private let activeWriterCount = Atomic<Int>(0)
    private let peakWriterCount = Atomic<Int>(0)

    public init(capacity: Int) {
        var size = 1
        while size < max(capacity, 1) { size <<= 1 }
        _capacity = size
        mask = size - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    public var capacity: Int { _capacity }

    /// Общее число записанных сэмплов с момента создания или `reset()`.
    public var totalWritten: Int { written.load(ordering: .acquiring) }

    /// Только для одного писателя.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        storeSamples(base, count: samples.count)
    }

    /// То же, что `write(_:)`, плюс метка блока: номер его первого сэмпла и `hostTicks`.
    /// Метка публикуется после сэмплов. Пустой блок ничего не меняет. Только для одного писателя.
    public func write(_ samples: UnsafeBufferPointer<Float>, hostTicks: UInt64) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        let first = storeSamples(base, count: samples.count)
        publishStamp(index: first, ticks: hostTicks)
    }

    /// Последняя метка блока; `nil` до первой записи с меткой и после `reset()`.
    public func latestStamp() -> RingStamp? {
        while true {
            let before = stampSequence.load(ordering: .acquiring)
            guard before & 1 == 0 else { continue }
            let index = stampIndex.load(ordering: .relaxed)
            let ticks = stampTicks.load(ordering: .relaxed)
            atomicMemoryFence(ordering: .acquiring)
            let after = stampSequence.load(ordering: .relaxed)
            guard after == before else { continue }
            return index < 0 ? nil : RingStamp(sampleIndex: index, hostTicks: ticks)
        }
    }

    /// Пишет пару через seqlock: номер нечетный, пара, номер четный. Только атомики, без
    /// блокировок, можно из аудио-колбэка.
    private func publishStamp(index: Int, ticks: UInt64) {
        let sequence = stampSequence.load(ordering: .relaxed)
        stampSequence.store(sequence &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        stampIndex.store(index, ordering: .relaxed)
        stampTicks.store(ticks, ordering: .relaxed)
        stampSequence.store(sequence &+ 2, ordering: .releasing)
    }

    /// Копирует сэмплы в кольцо и публикует их. Возвращает номер первого сэмпла блока.
    @discardableResult
    private func storeSamples(_ base: UnsafePointer<Float>, count n: Int) -> Int {
        let w = written.load(ordering: .relaxed)
        let newTotal = w + n
        claimed.store(newTotal, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)

        // Если блок больше емкости, достаточно сохранить его хвост.
        let keep = min(n, _capacity)
        let src = base + (n - keep)
        let startPos = (newTotal - keep) & mask
        let firstPart = min(keep, _capacity - startPos)
        (storage + startPos).update(from: src, count: firstPart)
        if keep > firstPart {
            storage.update(from: src + firstPart, count: keep - firstPart)
        }

        written.store(newTotal, ordering: .releasing)
        return w
    }

    /// Копирует `destination.count` сэмплов с номерами `endIndex - destination.count ..< endIndex`.
    /// Возвращает `false`, если таких сэмплов еще нет (окно в будущем или до нулевого сэмпла),
    /// окно длиннее кольца или уже перезаписано (в том числе во время копирования).
    public func copyWindow(endingAt endIndex: Int, into destination: UnsafeMutableBufferPointer<Float>) -> Bool {
        let count = destination.count
        guard count <= _capacity else { return false }
        let start = endIndex - count
        guard start >= 0 else { return false }

        let w = written.load(ordering: .acquiring)
        guard endIndex <= w, w - start <= _capacity else { return false }
        guard count > 0, let out = destination.baseAddress else { return true }

        let startPos = start & mask
        let firstPart = min(count, _capacity - startPos)
        out.update(from: storage + startPos, count: firstPart)
        if count > firstPart {
            (out + firstPart).update(from: storage, count: count - firstPart)
        }

        atomicMemoryFence(ordering: .acquiring)
        let c = claimed.load(ordering: .relaxed)
        return c - start <= _capacity
    }

    /// Копирует `destination.count` сэмплов, заканчивающихся на `totalWritten - delay`.
    /// Возвращает `false`, если данных еще мало или окно уже перезаписано.
    public func copyLatest(into destination: UnsafeMutableBufferPointer<Float>, delay: Int) -> Bool {
        let count = destination.count
        guard delay >= 0 else { return false }
        let need = delay + count
        guard need <= _capacity else { return false }
        guard count > 0, let out = destination.baseAddress else { return true }

        let w1 = written.load(ordering: .acquiring)
        guard w1 >= need else { return false }
        let start = w1 - need

        let startPos = start & mask
        let firstPart = min(count, _capacity - startPos)
        out.update(from: storage + startPos, count: firstPart)
        if count > firstPart {
            (out + firstPart).update(from: storage, count: count - firstPart)
        }

        atomicMemoryFence(ordering: .acquiring)
        let c = claimed.load(ordering: .relaxed)
        return c - start <= _capacity
    }

    /// Обнуляет историю и метку. Вызывать, когда писатель и читатель не работают.
    public func reset() {
        claimed.store(0, ordering: .relaxed)
        written.store(0, ordering: .releasing)
        publishStamp(index: -1, ticks: 0)
    }

    // MARK: - Учет писателей

    /// Писатель начал писать (IOProc запущен, таймер демо идет). Вызывается при запуске и
    /// остановке писателя, не из аудио-колбэка. Писателей больше одного быть не должно: это
    /// проверяют тесты по `peakWriters`.
    public func attachWriter() {
        let count = activeWriterCount.wrappingAdd(1, ordering: .relaxed).newValue
        var peak = peakWriterCount.load(ordering: .relaxed)
        while count > peak {
            let (exchanged, original) = peakWriterCount.compareExchange(
                expected: peak,
                desired: count,
                ordering: .relaxed
            )
            if exchanged { break }
            peak = original
        }
    }

    /// Писатель остановлен и больше не пишет.
    public func detachWriter() {
        activeWriterCount.wrappingSubtract(1, ordering: .relaxed)
    }

    /// Сколько писателей работает сейчас.
    public var activeWriters: Int { activeWriterCount.load(ordering: .relaxed) }

    /// Наибольшее число писателей, работавших одновременно, с момента создания.
    public var peakWriters: Int { peakWriterCount.load(ordering: .relaxed) }
}
