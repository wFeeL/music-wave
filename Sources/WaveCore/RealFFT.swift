import Foundation

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
    }

    /// Амплитудный спектр: `size / 2` значений, бин k соответствует частоте k * sampleRate / size.
    /// - Precondition: `samples.count == size`.
    public func amplitudeSpectrum(_ samples: [Float]) -> [Float] {
        precondition(samples.count == size, "samples.count must equal size")

        var re = [Float](repeating: 0, count: size)
        var im = [Float](repeating: 0, count: size)
        let half = size / 2
        var output = [Float](repeating: 0, count: half)

        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                // Окно и перестановка бит в одном проходе.
                for i in 0..<size {
                    re[Int(bitReversed[i])] = samples[i] * window[i]
                }

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

                for k in 0..<half {
                    output[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale
                }
            }
        }
        return output
    }
}
