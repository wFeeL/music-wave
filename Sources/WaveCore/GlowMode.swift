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

extension GlowMode {
    /// Режим настройки «Свечение» по умолчанию: «Ритм и звук».
    public static let settingDefault = GlowMode.hybrid

    /// Режим из сохраненной настройки (`wf.glowMode`, `rawValue`): без значения, с пустым или неизвестным
    /// словом (в том числе режим будущей версии) `settingDefault`.
    public static func setting(stored: String?) -> GlowMode {
        stored.flatMap(GlowMode.init(rawValue:)) ?? settingDefault
    }

    /// Название сегмента настройки «Свечение».
    public var title: String {
        switch self {
        case .rhythm: "По ритму"
        case .hybrid: "Ритм и звук"
        case .sound: "По звуку"
        }
    }
}
