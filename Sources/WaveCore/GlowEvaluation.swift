import Foundation

/// Счет свечения по режимам (`GlowMode`, разбор `2026-10-27-wavefeels-1.3-glow/analysis.md` §3): куда легли
/// все вспышки (на долю, на «и», мимо, `BeatMetrics.place`), яркие отдельно, реактивные отдельно, темнота и
/// видимые кадры. Вспышки не сливаются: глаз видит каждую.
extension BeatEvaluation {
    /// Яркая вспышка: пик свечения (`OfflineBeatChain.Flash.peak`) от этого значения. Реактивный слой
    /// «Ритм и звук» не ярче 0.6, поэтому яркие вспышки там это сетка и бочки 1.3.
    public static let strongPeak: Float = 0.65
    /// Темнота: промежутки без вспышек длиннее этого, секунды (`OwnerEvaluation.darkGap`).
    public static let glowDarkGap = 1.5
    /// Отрезок счета GTZAN: от первой размеченной доли минус столько до последней плюс столько, секунды.
    public static let glowSpanMargin = 0.3

    public struct GlowScore: Sendable, Equatable, Codable {
        public var flashes = 0
        public var on = 0
        public var half = 0
        public var other = 0
        /// Вспышки с пиком от `strongPeak` и где они.
        public var strong = 0
        public var strongOn = 0
        public var strongHalf = 0
        /// Вспышки реактивного слоя (`OfflineBeatChain.Flash.reactive`) и где они.
        public var reactive = 0
        public var reactiveOn = 0
        public var reactiveHalf = 0
        /// Сумма сдвигов вспышек на доле (всех и реактивных), мс, минус раньше.
        public var onOffsetSumMs = 0.0
        public var reactiveOnOffsetSumMs = 0.0
        /// Темнота на отрезке счета и его длина, секунды.
        public var darkSeconds = 0.0
        public var seconds = 0.0
        /// Кадров рендера, пока звук слышен, и сколько из них со свечением от `RhythmLog.ambientVisible`.
        public var frames = 0
        public var visibleFrames = 0

        public init() {}

        public mutating func add(_ other: GlowScore) {
            flashes += other.flashes
            on += other.on
            half += other.half
            self.other += other.other
            strong += other.strong
            strongOn += other.strongOn
            strongHalf += other.strongHalf
            reactive += other.reactive
            reactiveOn += other.reactiveOn
            reactiveHalf += other.reactiveHalf
            onOffsetSumMs += other.onOffsetSumMs
            reactiveOnOffsetSumMs += other.reactiveOnOffsetSumMs
            darkSeconds += other.darkSeconds
            seconds += other.seconds
            frames += other.frames
            visibleFrames += other.visibleFrames
        }

        private static func ratio(_ part: Int, _ total: Int) -> Double? {
            total > 0 ? Double(part) / Double(total) : nil
        }

        /// Доля вспышек на доле.
        public var onShare: Double? { Self.ratio(on, flashes) }
        /// Доля вспышек на доле или на «и».
        public var beatOrHalfShare: Double? { Self.ratio(on + half, flashes) }
        /// Точность ярких вспышек (на доле из ярких).
        public var strongPrecision: Double? { Self.ratio(strongOn, strong) }
        public var reactiveOnShare: Double? { Self.ratio(reactiveOn, reactive) }
        public var darkShare: Double? { seconds > 0 ? darkSeconds / seconds : nil }
        public var visibleShare: Double? { Self.ratio(visibleFrames, frames) }
        /// Средний сдвиг вспышек на доле, мс.
        public var onOffsetMs: Double? { on > 0 ? onOffsetSumMs / Double(on) : nil }
        public var reactiveOnOffsetMs: Double? { reactiveOn > 0 ? reactiveOnOffsetSumMs / Double(reactiveOn) : nil }
    }

    /// Счет вспышек `flashes` против долей `beats` (слышимая ось, по возрастанию) на отрезке `from...to`;
    /// кадры берутся из прогона как есть.
    public static func glow(
        flashes: [OfflineBeatChain.Flash], beats: [Double], from: Double, to: Double, window: Double, frames: Int, visibleFrames: Int
    ) -> GlowScore {
        var score = GlowScore()
        score.frames = frames
        score.visibleFrames = visibleFrames
        guard to > from else { return score }
        score.seconds = to - from
        let chosen = flashes.filter { $0.time >= from && $0.time <= to }
        for flash in chosen {
            let place = BeatMetrics.place(of: flash.time, beats: beats, window: window)
            let offset = place == .on ? (flash.time - beats[nearest(flash.time, in: beats)]) * 1000 : 0
            score.flashes += 1
            switch place {
            case .on:
                score.on += 1
                score.onOffsetSumMs += offset
            case .half: score.half += 1
            case .other: score.other += 1
            }
            if flash.peak >= strongPeak {
                score.strong += 1
                if place == .on { score.strongOn += 1 }
                if place == .half { score.strongHalf += 1 }
            }
            if flash.reactive {
                score.reactive += 1
                if place == .on {
                    score.reactiveOn += 1
                    score.reactiveOnOffsetSumMs += offset
                }
                if place == .half { score.reactiveHalf += 1 }
            }
        }
        score.darkSeconds = BeatMetrics.darkSpans(detections: chosen.map(\.time), from: from, to: to, gap: glowDarkGap).total
        return score
    }

    /// Индекс ближайшей доли (`beats` не пустой, по возрастанию).
    private static func nearest(_ time: Double, in beats: [Double]) -> Int {
        var low = 0
        var high = beats.count - 1
        while low < high {
            let middle = (low + high) / 2
            if beats[middle] < time { low = middle + 1 } else { high = middle }
        }
        if low > 0, abs(beats[low - 1] - time) <= abs(beats[low] - time) { return low - 1 }
        return low
    }

    public static let glowNotes = [
        "glow: flashes are not merged; on / half / other by BeatMetrics.place (window); on% = on / flashes, on+half% = (on + half) / flashes",
        "glow: strong = flashes whose peak (flash frame and the next) is >= 0.65 (the hybrid reactive layer stays <= 0.6), sPrec = strong on / strong; react = flashes started by a reactive event",
        "glow: dark = share of the span in gaps > 1.5 s without a flash; vis = share of render frames while the audio is audible with glow >= 0.05 (soft pulse not included)",
        "glow: GTZAN span = first annotated beat - 0.3 s ... last + 0.3 s (audible axis); owner span = the whole recording; offOn / offReact = mean offset of on-beat flashes, all / reactive (ms)",
    ]

    /// Таблица свечения по именованным строкам.
    public static func glowTable(title: String, rows: [(String, GlowScore)]) -> String {
        let width = max(8, rows.map(\.0.count).max() ?? 0)
        let heads = [
            "flashes", "on", "half", "other", "on%", "on+half%", "strong", "sOn", "sHalf", "sPrec", "react", "rOn", "rHalf", "rOn%",
            "dark", "vis", "offOn", "offReact",
        ]
        func fraction(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "-" }
        func ms(_ value: Double?) -> String { value.map { String(format: "%+.1f", $0) } ?? "-" }
        func right(_ text: String, _ count: Int) -> String {
            text.count >= count ? text : String(repeating: " ", count: count - text.count) + text
        }
        func pad(_ text: String) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
        var lines = [title, pad("group") + "  " + heads.map { right($0, max($0.count, 6)) }.joined(separator: " ")]
        for (name, score) in rows {
            let cells = [
                String(score.flashes), String(score.on), String(score.half), String(score.other), fraction(score.onShare),
                fraction(score.beatOrHalfShare), String(score.strong), String(score.strongOn), String(score.strongHalf),
                fraction(score.strongPrecision), String(score.reactive), String(score.reactiveOn), String(score.reactiveHalf),
                fraction(score.reactiveOnShare), fraction(score.darkShare), fraction(score.visibleShare), ms(score.onOffsetMs),
                ms(score.reactiveOnOffsetMs),
            ]
            lines.append(pad(name) + "  " + zip(cells, heads).map { right($0, max($1.count, 6)) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
