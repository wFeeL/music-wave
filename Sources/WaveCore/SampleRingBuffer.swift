import Synchronization

/// Кольцевой буфер сэмплов для одного писателя и одного читателя (SPSC).
///
/// Писатель (аудио-колбэк) вызывает `write` без блокировок и выделений памяти.
/// Читатель (таймер анализа) вызывает `copyLatest` по схеме seqlock: копирует окно
/// и проверяет, что писатель не успел его перезаписать.
public final class SampleRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let _capacity: Int
    /// Сколько сэмплов писатель уже опубликовал (данные доступны читателю).
    private let written = Atomic<Int>(0)
    /// Сколько сэмплов писатель успел заявить: растет до начала копирования,
    /// чтобы читатель увидел перезапись окна, которая еще не опубликована.
    private let claimed = Atomic<Int>(0)

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
        let w = written.load(ordering: .relaxed)
        let n = samples.count
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

    /// Обнуляет историю. Вызывать, когда писатель и читатель не работают.
    public func reset() {
        claimed.store(0, ordering: .relaxed)
        written.store(0, ordering: .releasing)
    }
}
