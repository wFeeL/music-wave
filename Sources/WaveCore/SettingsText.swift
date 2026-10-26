/// Подписи и значения строк окна настроек, которые считаются, а не пишутся как есть: значения
/// ползунков «Скорость переливания» и «Задержка раскрытия», подпись «Автовыбора источника» и
/// подпись под «Стилем».
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

    /// Подпись «Автовыбора источника»: выключен, что он делает; включен, какой источник
    /// у волн сейчас (`current`, имя `AppModel.effectiveSource`).
    public static func autoSource(enabled: Bool, current: String) -> String {
        enabled ? "Сейчас: \(current)" : "Волны переходят к приложению, которое начало играть"
    }

    /// Подпись под «Стилем»: «Пульс» при системном «Уменьшении движения» не дышит
    /// (свечение и вздох выключены), об этом сказано прямо. У остальных стилей подписи нет.
    public static func lookCaption(_ look: WaveLook, reduceMotion: Bool) -> String? {
        guard reduceMotion, look == .pulse else { return nil }
        return "При уменьшении движения остров не дышит"
    }
}

extension WaveLook {
    /// Стилю нужна строка «Количество волн»: число линий меняется только у «Волн».
    public var usesLineCount: Bool {
        switch self {
        case .waves: true
        case .spectrum, .minimal, .pulse: false
        }
    }

    /// Стилю нужна «Заливка»: та же граница, что у `WaveAppearance.effectiveFill`.
    public var usesFill: Bool {
        switch self {
        case .waves, .spectrum: true
        case .minimal, .pulse: false
        }
    }

    /// Стилю нужны «Толщина линий» и «Размах»: у «Пульса» на острове бегущих линий нет.
    public var usesStroke: Bool {
        switch self {
        case .waves, .spectrum, .minimal: true
        case .pulse: false
        }
    }
}
