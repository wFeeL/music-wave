/// Длина записи ритма («Записать 2 мин» в разделе «Ритм» диагностики): допустимые секунды,
/// быстрые значения, подписи кнопки и хода записи, разбор ввода «минуты и секунды».
///
/// Память: запись держит звук как Int16 моно, при 48 кГц около 5,8 МБ в минуту, на 10 минут
/// около 58 МБ; WAV пишется кусками (`WAVWriter.write`), второй копии звука нет.
public enum RhythmRecordingLength {
    /// От 10 с до 10 мин.
    public static let range: ClosedRange<Int> = 10...600
    /// По умолчанию 2 мин.
    public static let defaultSeconds = 120
    /// Быстрые значения: 30 с, 1, 2 и 5 мин.
    public static let presets: [Int] = [30, 60, 120, 300]

    /// Секунды в `range`; дробное округляется, не число дает `defaultSeconds`.
    public static func normalized(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return defaultSeconds }
        return Int(min(max(seconds.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
    }

    /// Секунды в `range`; вне него обрезаются.
    public static func normalized(_ seconds: Int) -> Int {
        min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// Длина из полей «минуты» и «секунды»: `minutes * 60 + seconds`, затем `normalized`. Пустое
    /// поле это 0, отрицательное тоже; 90 секунд без минут это 1 мин 30 с.
    public static func combine(minutes: Int, seconds: Int) -> Int {
        let total = max(minutes, 0).multipliedReportingOverflow(by: 60)
        guard !total.overflow else { return range.upperBound }
        let sum = total.partialValue.addingReportingOverflow(max(seconds, 0))
        return sum.overflow ? range.upperBound : normalized(sum.partialValue)
    }

    /// Число из текста поля: цифры без пробелов и знаков, пустой или нецифровой текст это 0,
    /// слишком длинное число это `Int.max` (дальше его обрежет `combine`).
    public static func parse(_ text: String) -> Int {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return 0 }
        return Int(digits) ?? Int.max
    }

    /// «45 с», «1 мин», «2 мин», «1 мин 30 с»; секунды берутся как есть, меньше 0 это 0.
    public static func text(seconds: Int) -> String {
        let value = max(seconds, 0)
        guard value >= 60 else { return "\(value) с" }
        let rest = value % 60
        return rest == 0 ? "\(value / 60) мин" : "\(value / 60) мин \(rest) с"
    }

    /// Подпись кнопки: «Записать 2 мин», «Записать 45 с».
    public static func buttonTitle(seconds: Int) -> String {
        "Записать " + text(seconds: seconds)
    }

    /// Подпись кнопки во время записи: «Запись… 45 с», «Запись… 1 мин 5 с».
    public static func progressTitle(seconds: Int) -> String {
        "Запись… " + text(seconds: seconds)
    }
}
