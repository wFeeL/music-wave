import Foundation
import Synchronization

/// БПФ вещественного сигнала с окном Ханна, возвращает спектр амплитуд.
///
/// Внутри итеративный radix-2 комплексный БПФ размера `size`; таблицы окна,
/// поворотов и перестановки бит считаются один раз в `init`.
public struct RealFFT: Sendable {
    public let size: Int

    private let window: [Float]
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReversed: [Int32]
    private let scale: Float
    private let scratch: FFTScratch

    /// - Parameter size: степень двойки не меньше 2.
    public init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "size must be a power of two")
        self.size = size

        // Периодическое окно Ханна: w[n] = 0.5 - 0.5 cos(2 pi n / N).
        var windowSum = 0.0
        let window = (0..<size).map { n -> Float in
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(size))
            windowSum += w
            return Float(w)
        }
        self.window = window
        // Нормировка на сумму окна и множитель 2: синус амплитуды A в центре бина дает пик A.
        scale = Float(2 / windowSum)

        let half = size / 2
        cosTable = (0..<half).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<half).map { Float(-sin(2 * Double.pi * Double($0) / Double(size))) }

        let bits = size.trailingZeroBitCount
        bitReversed = (0..<size).map { index in
            var reversed = 0
            for bit in 0..<bits where index & (1 << bit) != 0 {
                reversed |= 1 << (bits - 1 - bit)
            }
            return Int32(reversed)
        }
        scratch = FFTScratch(count: 2 * size)
    }

    /// Амплитудный спектр: `size / 2` значений, бин k соответствует частоте k * sampleRate / size.
    /// - Precondition: `samples.count == size`.
    public func amplitudeSpectrum(_ samples: [Float]) -> [Float] {
        precondition(samples.count == size, "samples.count must equal size")
        var output = [Float](repeating: 0, count: size / 2)
        var scratch = [Float](repeating: 0, count: 2 * size)
        samples.withUnsafeBufferPointer { samples in
            output.withUnsafeMutableBufferPointer { output in
                scratch.withUnsafeMutableBufferPointer { scratch in
                    transform(samples, scratch: scratch, into: output)
                }
            }
        }
        return output
    }

    /// То же, что `amplitudeSpectrum(_:)`, но в готовый буфер и без выделения памяти: рабочие
    /// массивы созданы в `init`. Вызовы с разных потоков на одном экземпляре идут по очереди.
    /// - Precondition: `samples.count == size`, `output.count == size / 2`.
    public func amplitudeSpectrum(_ samples: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Float>) {
        precondition(samples.count == size, "samples.count must equal size")
        precondition(output.count == size / 2, "output.count must equal size / 2")
        scratch.buffer.withLock { buffer in
            buffer.withUnsafeMutableBufferPointer { transform(samples, scratch: $0, into: output) }
        }
    }

    /// Окно, БПФ и модуль. `scratch` это `2 * size` значений: действительные части, затем мнимые.
    private func transform(
        _ samples: UnsafeBufferPointer<Float>,
        scratch: UnsafeMutableBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let re = UnsafeMutableBufferPointer(rebasing: scratch[0..<size])
        let im = UnsafeMutableBufferPointer(rebasing: scratch[size..<(2 * size)])
        let half = size / 2

        window.withUnsafeBufferPointer { window in
            bitReversed.withUnsafeBufferPointer { bitReversed in
                // Окно и перестановка бит в одном проходе: перестановка взаимно однозначна,
                // поэтому каждый элемент `re` записан.
                for i in 0..<size {
                    re[Int(bitReversed[i])] = samples[i] * window[i]
                    im[i] = 0
                }
            }
        }

        cosTable.withUnsafeBufferPointer { cosTable in
            sinTable.withUnsafeBufferPointer { sinTable in
                var length = 2
                while length <= size {
                    let halfLength = length / 2
                    let step = size / length
                    var start = 0
                    while start < size {
                        for k in 0..<halfLength {
                            let wr = cosTable[k * step]
                            let wi = sinTable[k * step]
                            let a = start + k
                            let b = a + halfLength
                            let tr = re[b] * wr - im[b] * wi
                            let ti = re[b] * wi + im[b] * wr
                            re[b] = re[a] - tr
                            im[b] = im[a] - ti
                            re[a] += tr
                            im[a] += ti
                        }
                        start += length
                    }
                    length <<= 1
                }
            }
        }

        for k in 0..<half {
            output[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale
        }
    }
}

/// Рабочий массив `amplitudeSpectrum(_:into:)`. Класс, чтобы копии `RealFFT` и вызов без
/// `mutating` делили одно выделение; мьютекс не дает двум потокам писать в него разом.
private final class FFTScratch: Sendable {
    let buffer: Mutex<[Float]>

    init(count: Int) {
        buffer = Mutex([Float](repeating: 0, count: count))
    }
}
