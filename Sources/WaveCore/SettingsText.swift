/// Подписи и значения строк окна настроек, которые считаются, а не пишутся как есть: значения
/// ползунков «Скорость переливания» и «Задержка раскрытия», подсказка «Длительности вспышки», подписи «Свечения»
/// и «Автовыбора источника».
public enum SettingsText {
    /// Значение «Скорости переливания»: «Выкл» без переливания, иначе период полного оборота
    /// `PaletteFlow.period(speed:)` до десятых секунды («12 с», «19,4 с»). Соседние шаги ползунка
    /// (0.05) различаются на 0.6 с, поэтому показывают разные числа.
    public static func colorFlow(speed: Double) -> String {
        guard let period = PaletteFlow.period(speed: speed) else { return "Выкл" }
        return seconds((period * 10).rounded() / 10)
    }

    /// Секунды до сотых через запятую, без нулей в конце: «0,15 с», «0,2 с», «1 с».
    /// Отрицательное и не конечное значение дает «0 с».
    public static func seconds(_ value: Double) -> String {
        let hundredths = value.isFinite ? max(Int((value * 100).rounded()), 0) : 0
        let whole = hundredths / 100
        let fraction = hundredths % 100
        if fraction == 0 { return "\(whole) с" }
        if fraction % 10 == 0 { return "\(whole),\(fraction / 10) с" }
        return "\(whole),\(fraction < 10 ? "0" : "")\(fraction) с"
    }

    /// Подсказка под «Длительностью вспышки» (множитель спада 0.5...2): короче обычной, обычная, длиннее.
    /// Шаг ползунка 0.1, поэтому от 0.95 до 1.05 вспышка обычная; не конечное значение тоже обычное.
    public static func flashLengthHint(scale: Double) -> String {
        guard scale.isFinite else { return "Обычные вспышки" }
        if scale < 0.95 { return "Короткие вспышки" }
        if scale > 1.05 { return "Длинные вспышки" }
        return "Обычные вспышки"
    }

    /// Подпись под «Частотой кадров» (30 или 60 кадров в секунду).
    public static let frameRateCaption = "30 экономит заряд, 60 плавнее"

    /// Подпись под настройкой «Свечение»: что делает выбранный режим (`GlowMode`).
    public static func glowModeCaption(_ mode: GlowMode) -> String {
        switch mode {
        case .rhythm: "Вспышки только на долях"
        case .hybrid: "Доли плюс мягкие вспышки на сильных звуках"
        case .sound: "Вспышки на ударах и нотах баса, как у волн"
        }
    }

    /// Подпись «Автовыбора источника»: выключен, что он делает; включен, какой источник
    /// у волн сейчас (`current`, имя `AppModel.effectiveSource`).
    public static func autoSource(enabled: Bool, current: String) -> String {
        enabled ? "Сейчас: \(current)" : "Волны переходят к приложению, которое начало играть"
    }
}

extension WaveLook {
    /// Стилю нужна строка «Количество волн»: число линий меняется только у «Волн».
    public var usesLineCount: Bool {
        switch self {
        case .waves: true
        case .spectrum: false
        }
    }

    /// Стилю нужна строка «След пиков» (`WaveAppearance.spectrumPeaks`): призрак пика есть
    /// только у «Спектра».
    public var usesSpectrumPeaks: Bool {
        switch self {
        case .waves: false
        case .spectrum: true
        }
    }
}
