import Foundation
import Synchronization

/// БПФ вещественного сигнала с окном Ханна, возвращает спектр амплитуд.
///
/// Внутри итеративный radix-2 комплексный БПФ размера `size`; таблицы окна,
/// поворотов и перестановки бит считаются один раз в `init`. Бабочки этапов от четырех пар
/// идут по четыре в векторах `SIMD4`: каждая дорожка делает те же умножения и сложения в том
/// же порядке, что скалярная бабочка, поэтому спектр бит в бит прежний.
public struct RealFFT: Sendable {
    public let size: Int

    private let window: [Float]
    /// Повороты подряд для каждого этапа: у этапа с `h` парами в блоке они лежат с `h - 1`,
    /// k-й равен `cos` и `-sin` от `2π k (size / 2h) / size`.
    private let stageCos: [Float]
    private let stageSin: [Float]
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
        let cosTable = (0..<half).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        let sinTable = (0..<half).map { Float(-sin(2 * Double.pi * Double($0) / Double(size))) }
        var stageCos = [Float]()
        var stageSin = [Float]()
        stageCos.reserveCapacity(size - 1)
        stageSin.reserveCapacity(size - 1)
        var pairs = 1
        while pairs <= half {
            let step = size / (2 * pairs)
            for k in 0..<pairs {
                stageCos.append(cosTable[k * step])
                stageSin.append(sinTable[k * step])
            }
            pairs <<= 1
        }
        self.stageCos = stageCos
        self.stageSin = stageSin

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

    /// То же в готовый массив `output` (`size / 2` значений), без выделения памяти. Шаг анализа
    /// вызывает этот вариант без замыкания вокруг себя: внутри замыкания чтение БПФ из свойства
    /// копировало бы всю структуру (удержание каждого ее массива) на каждом шаге.
    /// - Precondition: `samples.count == size`, `output.count == size / 2`.
    func amplitudeSpectrum(_ samples: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        output.withUnsafeMutableBufferPointer { amplitudeSpectrum(samples, into: $0) }
    }

    /// Адрес и емкость рабочего массива для теста: вызовы его не пересоздают.
    var workBuffer: WorkBuffer {
        scratch.buffer.withLock { WorkBuffer($0) }
    }

    /// Окно, БПФ и модуль. `scratch` это `2 * size` значений: действительные части, затем мнимые.
    private func transform(
        _ samples: UnsafeBufferPointer<Float>,
        scratch: UnsafeMutableBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let size = size
        let half = size / 2
        guard let re = scratch.baseAddress, let out = output.baseAddress else { return }
        let im = re + size

        window.withUnsafeBufferPointer { window in
            bitReversed.withUnsafeBufferPointer { bitReversed in
                // Окно и перестановка бит в одном проходе: перестановка взаимно однозначна,
                // поэтому каждый элемент `re` записан.
                for i in 0..<size {
                    re[Int(bitReversed[i])] = samples[i] * window[i]
                }
            }
        }
        im.update(repeating: 0, count: size)

        stageCos.withUnsafeBufferPointer { stageCos in
            stageSin.withUnsafeBufferPointer { stageSin in
                guard let cosBase = stageCos.baseAddress, let sinBase = stageSin.baseAddress else { return }
                var pairs = 1
                while pairs <= half {
                    let length = 2 * pairs
                    let wr = cosBase + (pairs - 1)
                    let wi = sinBase + (pairs - 1)
                    var start = 0
                    if pairs >= 4 {
                        while start < size {
                            var k = 0
                            while k < pairs {
                                Self.butterflies4(re: re, im: im, a: start + k, b: start + k + pairs, wr: wr + k, wi: wi + k)
                                k += 4
                            }
                            start += length
                        }
                    } else {
                        while start < size {
                            for k in 0..<pairs {
                                Self.butterfly(re: re, im: im, a: start + k, b: start + k + pairs, wr: wr[k], wi: wi[k])
                            }
                            start += length
                        }
                    }
                    pairs <<= 1
                }
            }
        }

        let scale = scale
        var k = 0
        if half >= 4 {
            let scale4 = SIMD4<Float>(repeating: scale)
            while k < half {
                let r = Self.load4(re + k)
                let i = Self.load4(im + k)
                Self.store4((r * r + i * i).squareRoot() * scale4, to: out + k)
                k += 4
            }
        }
        while k < half {
            out[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale
            k += 1
        }
    }

    /// Бабочка пары `a`, `b` с поворотом `(wr, wi)`.
    @inline(__always)
    private static func butterfly(
        re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, a: Int, b: Int, wr: Float, wi: Float
    ) {
        let tr = re[b] * wr - im[b] * wi
        let ti = re[b] * wi + im[b] * wr
        re[b] = re[a] - tr
        im[b] = im[a] - ti
        re[a] += tr
        im[a] += ti
    }

    /// Четыре бабочки подряд: пары `a + j`, `b + j` с поворотами `wr[j]`, `wi[j]`, j = 0...3.
    /// Каждая дорожка считает ровно то же, что `butterfly`.
    @inline(__always)
    private static func butterflies4(
        re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, a: Int, b: Int,
        wr: UnsafePointer<Float>, wi: UnsafePointer<Float>
    ) {
        let cosines = load4(wr)
        let sines = load4(wi)
        let reA = load4(re + a)
        let imA = load4(im + a)
        let reB = load4(re + b)
        let imB = load4(im + b)
        let tr = reB * cosines - imB * sines
        let ti = reB * sines + imB * cosines
        store4(reA - tr, to: re + b)
        store4(imA - ti, to: im + b)
        store4(reA + tr, to: re + a)
        store4(imA + ti, to: im + a)
    }

    @inline(__always)
    private static func load4(_ pointer: UnsafePointer<Float>) -> SIMD4<Float> {
        UnsafeRawPointer(pointer).loadUnaligned(as: SIMD4<Float>.self)
    }

    @inline(__always)
    private static func load4(_ pointer: UnsafeMutablePointer<Float>) -> SIMD4<Float> {
        UnsafeRawPointer(pointer).loadUnaligned(as: SIMD4<Float>.self)
    }

    @inline(__always)
    private static func store4(_ value: SIMD4<Float>, to pointer: UnsafeMutablePointer<Float>) {
        UnsafeMutableRawPointer(pointer).storeBytes(of: value, as: SIMD4<Float>.self)
    }
}

/// Адрес и емкость буфера: по ним тест видит, что буфер не пересоздан и не вырос.
struct WorkBuffer: Hashable, Sendable {
    let address: UInt
    let capacity: Int

    init(_ array: [Float]) {
        address = array.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        capacity = array.capacity
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
