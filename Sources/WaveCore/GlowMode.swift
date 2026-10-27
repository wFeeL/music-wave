import Foundation

/// Режим свечения (настройка «Свечение», решение владельца 2026-10-27). Решает, какие события расписания
/// `BeatTracker` публикует для показа; анализ, темп, фаза, захват и мягкий пульс от режима не зависят.
///
/// - `rhythm` («По ритму»): сетка долей и онсеты бочки, как в 1.3. Расписание то же байт в байт.
/// - `hybrid` («Ритм и звук»): сетка и бочки как в `rhythm` плюс мягкий реактивный слой
///   (`ReactiveGlow`): вспышки на сильных атаках звука, приглушенные вне сетки, когда сетке верят.
/// - `sound` («По звуку»): только реактивные вспышки в полную яркость, сетка и бочки не светятся.
public enum GlowMode: String, CaseIterable, Sendable, Codable {
    case rhythm
    case hybrid
    case sound

    /// Нужен ли режиму уровень баса анализа (`StreamAnalyzer.measuresBassLevel`): ноты баса реактивного слоя.
    public var measuresBassLevel: Bool { self != .rhythm }

    /// Единая точка настройки режима: ставит трекеру `glowMode` и анализу `measuresBassLevel` вместе, чтобы
    /// приложение не забыло половину (без уровня баса в `hybrid` и `sound` нет нот баса). Зовется при
    /// создании и при каждой смене режима на очереди анализа; смена начинает реактивный слой заново.
    public func apply(to analyzer: StreamAnalyzer, tracker: inout BeatTracker) {
        analyzer.measuresBassLevel = measuresBassLevel
        tracker.glowMode = self
    }
}
