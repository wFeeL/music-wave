import Foundation

/// Детерминированный генератор (SplitMix64) для k-means и тестов.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Цвет в OKLab (Björn Ottosson).
public struct OKLab: Sendable, Equatable {
    public var l, a, b: Float

    public init(l: Float, a: Float, b: Float) {
        self.l = l
        self.a = a
        self.b = b
    }

    public var chroma: Float { (a * a + b * b).squareRoot() }

    /// Евклидово расстояние по (L, a, b).
    func distance(to other: OKLab) -> Float {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// Поворот (a, b) на `degrees` при неизменном L.
    func rotatedHue(degrees: Float) -> OKLab {
        let theta = degrees * .pi / 180
        let c = cos(theta), s = sin(theta)
        return OKLab(l: l, a: a * c - b * s, b: a * s + b * c)
    }

    /// Линейный sRGB без обрезки: значения вне 0...1 означают выход за гамму.
    var linearRGB: (r: Double, g: Double, b: Double) {
        let l = Double(self.l), a = Double(self.a), b = Double(self.b)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        return (
            4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
            -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
            -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
    }

    var isInSRGBGamut: Bool {
        let rgb = linearRGB
        let eps = 1e-5
        return [rgb.r, rgb.g, rgb.b].allSatisfy { $0 >= -eps && $0 <= 1 + eps }
    }
}

/// sRGB с гамма-кривой, значения 0...1.
public struct RGBColor: Sendable, Equatable, Codable {
    public var r, g, b: Float

    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(
            r: Float((hex >> 16) & 0xFF) / 255,
            g: Float((hex >> 8) & 0xFF) / 255,
            b: Float(hex & 0xFF) / 255)
    }

    public var oklab: OKLab {
        let r = Self.toLinear(Double(self.r)), g = Self.toLinear(Double(self.g)), b = Self.toLinear(Double(self.b))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(
            l: Float(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s),
            a: Float(1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s),
            b: Float(0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s))
    }

    /// Значения вне гаммы sRGB обрезаются до 0...1.
    public init(oklab: OKLab) {
        let linear = oklab.linearRGB
        self.init(
            r: Float(Self.fromLinear(linear.r)),
            g: Float(Self.fromLinear(linear.g)),
            b: Float(Self.fromLinear(linear.b)))
    }

    var isFinite: Bool { r.isFinite && g.isFinite && b.isFinite }

    private static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func fromLinear(_ c: Double) -> Double {
        let v = min(max(c, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

public enum PaletteExtractor {
    public static let fallback: [RGBColor] = [
        RGBColor(hex: 0x8B5CF6), RGBColor(hex: 0x22D3EE), RGBColor(hex: 0xF472B6),
    ]

    private static let minimumShare = 0.05
    private static let maxClusters = 5
    private static let iterations = 12
    private static let minimumSeparation: Float = 0.08
    private static let liftedLightness: Float = 0.62

    /// Три акцентных цвета обложки. `rgba` это 4 байта на пиксель, строки подряд.
    public static func extract(rgba: [UInt8], width: Int, height: Int) -> [RGBColor] {
        let pixelCount = min(width * height, rgba.count / 4)
        guard pixelCount > 0 else { return fallback }

        var points: [SIMD3<Float>] = []
        var distinct = Set<UInt32>()
        for i in 0..<pixelCount {
            let o = i * 4
            guard rgba[o + 3] >= 128 else { continue }
            let color = RGBColor(
                r: Float(rgba[o]) / 255, g: Float(rgba[o + 1]) / 255, b: Float(rgba[o + 2]) / 255)
            let lab = color.oklab
            guard lab.l >= 0.12, lab.l <= 0.95, lab.chroma >= 0.04 else { continue }
            points.append(SIMD3(lab.l, lab.a, lab.b))
            distinct.insert(UInt32(rgba[o]) << 16 | UInt32(rgba[o + 1]) << 8 | UInt32(rgba[o + 2]))
        }
        guard Double(points.count) >= minimumShare * Double(pixelCount) else { return fallback }

        let (centers, counts) = kMeans(points: points, k: min(maxClusters, distinct.count))

        // Лучшие кластеры по оценке доли и насыщенности, попарно различимые.
        let total = Float(points.count)
        let ranked = centers.indices
            .filter { counts[$0] > 0 }
            .map { index -> (lab: OKLab, score: Float) in
                let c = centers[index]
                let lab = OKLab(l: c.x, a: c.y, b: c.z)
                return (lab, Float(counts[index]) / total * (0.3 + 4 * lab.chroma))
            }
            .sorted { $0.score > $1.score }

        var chosen: [OKLab] = []
        for candidate in ranked where chosen.count < 3 {
            if chosen.allSatisfy({ $0.distance(to: candidate.lab) > minimumSeparation }) {
                chosen.append(candidate.lab)
            }
        }
        if chosen.count < 3 {
            let rotated = [40, -40].map { chosen[0].rotatedHue(degrees: Float($0)) }
            for candidate in rotated where chosen.count < 3 {
                if chosen.allSatisfy({ $0.distance(to: candidate) > minimumSeparation }) {
                    chosen.append(candidate)
                }
            }
            for candidate in rotated where chosen.count < 3 && !chosen.contains(candidate) {
                chosen.append(candidate)
            }
        }
        return ensureThree(chosen.map { RGBColor(oklab: brightened($0)) })
    }

    /// Всегда ровно 3 конечных цвета: недостающие получаются сдвигом L первого цвета на 0.08 и 0.16,
    /// а если и этого мало, первый цвет повторяется.
    static func ensureThree(_ colors: [RGBColor]) -> [RGBColor] {
        var result = colors.prefix(3).enumerated().map { index, color in
            color.isFinite ? color : fallback[index]
        }
        if result.isEmpty { return fallback }
        let base = result[0].oklab
        for offset: Float in [0.08, -0.08, 0.16, -0.16] where result.count < 3 {
            let l = base.l + offset
            guard l >= liftedLightness, l <= 0.97 else { continue }
            let candidate = RGBColor(oklab: brightened(OKLab(l: l, a: base.a, b: base.b)))
            if candidate.isFinite { result.append(candidate) }
        }
        while result.count < 3 { result.append(result[0]) }
        return result
    }

    /// K-means в OKLab, старт k-means++ на SplitMix64(seed: 42). Возвращает центры и размеры кластеров.
    private static func kMeans(points: [SIMD3<Float>], k: Int) -> (centers: [SIMD3<Float>], counts: [Int]) {
        var rng = SplitMix64(seed: 42)
        var centers = [points[Int(rng.next() % UInt64(points.count))]]

        while centers.count < k {
            let weights = points.map { p in centers.map { squaredDistance(p, $0) }.min()! }
            let sum = weights.reduce(0.0) { $0 + Double($1) }
            guard sum > 0 else { break }
            let target = Double(rng.next() >> 11) / Double(1 << 53) * sum
            var running = 0.0
            var pick = points.count - 1
            for (i, w) in weights.enumerated() {
                running += Double(w)
                if running > target {
                    pick = i
                    break
                }
            }
            centers.append(points[pick])
        }

        var counts = [Int](repeating: 0, count: centers.count)
        for _ in 0..<iterations {
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count)
            counts = [Int](repeating: 0, count: centers.count)
            for p in points {
                var best = 0
                var bestDistance = Float.infinity
                for (j, c) in centers.enumerated() {
                    let d = squaredDistance(p, c)
                    if d < bestDistance {
                        bestDistance = d
                        best = j
                    }
                }
                sums[best] += SIMD3<Double>(p)
                counts[best] += 1
            }
            for j in centers.indices where counts[j] > 0 {
                centers[j] = SIMD3<Float>(sums[j] / Double(counts[j]))
            }
        }
        return (centers, counts)
    }

    private static func squaredDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum()
    }

    /// Поднимает L до 0.62 (chroma x 1.3) и возвращает цвет в гамму sRGB бисекцией по chroma при том же L.
    private static func brightened(_ color: OKLab) -> OKLab {
        var lab = color
        if lab.l < liftedLightness {
            lab = OKLab(l: liftedLightness, a: lab.a * 1.3, b: lab.b * 1.3)
        }
        guard !lab.isInSRGBGamut else { return lab }

        var low: Float = 0
        var high: Float = 1
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if OKLab(l: lab.l, a: lab.a * mid, b: lab.b * mid).isInSRGBGamut {
                low = mid
            } else {
                high = mid
            }
        }
        return OKLab(l: lab.l, a: lab.a * low, b: lab.b * low)
    }
}

/// Смешивает палитры в OKLab, `t` ограничивается 0...1.
public func mixPalettes(_ a: [RGBColor], _ b: [RGBColor], t: Float) -> [RGBColor] {
    let t = t.isNaN ? 0 : min(max(t, 0), 1)
    if t == 0 { return a }
    if t == 1 { return b }
    return zip(a, b).map { from, to in
        let x = from.oklab, y = to.oklab
        return RGBColor(oklab: OKLab(
            l: x.l + (y.l - x.l) * t,
            a: x.a + (y.a - x.a) * t,
            b: x.b + (y.b - x.b) * t))
    }
}

/// Плавная смена палитры: к новой цели за `duration` секунд с ease-in-out через `mixPalettes`.
/// Новая цель посреди перехода начинает свой переход от того, что видно сейчас, без скачка.
public struct PaletteFade: Sendable {
    public static let duration = 0.8

    private var from: [RGBColor]
    private var to: [RGBColor]
    private var start: Double?

    public init(palette: [RGBColor]) {
        from = palette
        to = palette
    }

    /// Палитра на момент `now` (секунды, любые монотонные часы).
    public mutating func palette(target: [RGBColor], now: Double) -> [RGBColor] {
        if target != to {
            from = shown(at: now)
            to = target
            start = now.isFinite ? now : nil
        }
        return shown(at: now)
    }

    private mutating func shown(at now: Double) -> [RGBColor] {
        guard let start else { return to }
        guard now.isFinite else {
            self.start = nil
            return to
        }
        let raw = (now - start) / Self.duration
        if raw >= 1 - 1e-9 {
            self.start = nil
            return to
        }
        let t = min(max(raw, 0), 1)
        return mixPalettes(from, to, t: Float(t * t * (3 - 2 * t)))
    }
}
