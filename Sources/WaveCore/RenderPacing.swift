import Foundation

/// Состояние острова для замера отрисовки: свернутый (и скрытый), раскрытый и переход между
/// ними (первая секунда после смены состояния).
public enum RenderBucket: String, CaseIterable, Sendable {
    case collapsed
    case expanded
    case transition

    /// Корзина кадра: переход в пределах `RenderPacing.transitionWindow` после смены состояния,
    /// иначе по состоянию; скрытый остров считается свернутым.
    public static func classify(state: IslandState, sinceStateChange: Double) -> RenderBucket {
        if sinceStateChange < RenderPacing.transitionWindow {
            return .transition
        }
        switch state {
        case .expanded: return .expanded
        case .collapsed, .hidden: return .collapsed
        }
    }

    /// Корзины, чьи строки замера раз в 10 с пишутся в лог приложения: в замере CPU (`probe`,
    /// запуск с `--settings-suite`) свернутая и раскрытая в любом состоянии острова, иначе
    /// только раскрытая и только пока остров раскрыт.
    public static func logged(state: IslandState, probe: Bool) -> [RenderBucket] {
        if probe { return [.collapsed, .expanded] }
        return state == .expanded ? [.expanded] : []
    }
}

/// Сводка по одной корзине. Доли от 0 до 1, времена в миллисекундах.
public struct RenderPacingSummary: Sendable, Equatable, CustomStringConvertible {
    /// Сколько интервалов в замере.
    public var frames: Int
    /// Интервал меньше 1.5 периода экрана.
    public var onTime: Double
    /// От 1.5 до 2.5 периода: пропущен один кадр экрана.
    public var oneMissed: Double
    /// От 2.5 периода: пропущено два кадра и больше.
    public var twoOrMore: Double
    public var p50Ms: Double
    public var p95Ms: Double
    public var maxMs: Double
    /// Стандартное отклонение интервала между кадрами по часам хоста.
    public var intervalSigmaMs: Double
    /// Стандартное отклонение шага шкалы `TimelineView` (`context.date`).
    public var timelineSigmaMs: Double
    /// Доли кадров, на которые пришло 0, 1, 2 и 3+ новых кадров анализа.
    public var analysisFrames: [Double]
    /// Кадров в секунду, пока остров рисуется: интервалы замера, деленные на их сумму. Паузы
    /// длиннее `RenderPacing.maxGap` и простой (`RenderPacing.restart()`) не в счет.
    public var framesPerSecond: Double

    public init(
        frames: Int, onTime: Double, oneMissed: Double, twoOrMore: Double,
        p50Ms: Double, p95Ms: Double, maxMs: Double,
        intervalSigmaMs: Double, timelineSigmaMs: Double, analysisFrames: [Double],
        framesPerSecond: Double
    ) {
        self.frames = frames
        self.onTime = onTime
        self.oneMissed = oneMissed
        self.twoOrMore = twoOrMore
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.intervalSigmaMs = intervalSigmaMs
        self.timelineSigmaMs = timelineSigmaMs
        self.analysisFrames = analysisFrames
        self.framesPerSecond = framesPerSecond
    }

    /// «3600 кадров | вовремя 99.1 % | 1 пропуск 0.8 % | 2+ 0.1 % | p50 16.7 мс | p95 16.9 мс | max 34 мс».
    public var pacingText: String {
        [
            "\(frames) кадров",
            "вовремя \(Self.percent(onTime))",
            "1 пропуск \(Self.percent(oneMissed))",
            "2+ \(Self.percent(twoOrMore))",
            "p50 \(Self.milliseconds(p50Ms))",
            "p95 \(Self.milliseconds(p95Ms))",
            "max \(String(format: "%.0f", maxMs)) мс",
        ].joined(separator: " | ")
    }

    /// `pacingText` и частота кадров: «... | max 34 мс | 59.8 кадров/с». Так строка замера
    /// пишется в лог, оттуда ее берет scripts/cpu-probe.sh.
    public var description: String {
        "\(pacingText) | \(String(format: "%.1f", framesPerSecond)) кадров/с"
    }

    /// «0: 4 % | 1: 92 % | 2: 4 % | 3+: 0 %».
    public var analysisFramesText: String {
        let labels = ["0", "1", "2", "3+"]
        return zip(labels, analysisFrames)
            .map { label, share in "\(label): \(Int((share * 100).rounded())) %" }
            .joined(separator: " | ")
    }

    /// «интервал σ 0.6 мс | шкала σ 0.4 мс».
    public var spreadText: String {
        "интервал σ \(Self.milliseconds(intervalSigmaMs)) | шкала σ \(Self.milliseconds(timelineSigmaMs))"
    }

    private static func percent(_ share: Double) -> String {
        String(format: "%.1f %%", share * 100)
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.1f мс", value)
    }
}

/// Замер отрисовки острова без Instruments: интервалы между кадрами по корзинам
/// (`RenderBucket`), шаг шкалы `TimelineView` и сколько кадров анализа приходит на кадр.
/// Значение живет на главном акторе модели, блокировок нет.
public struct RenderPacing: Sendable {
    /// Сколько последних кадров хранится в каждой корзине (минута при 60 Гц).
    public static let window = 3600
    /// Пауза длиннее этой не считается интервалом: замер начинается заново.
    public static let maxGap = 0.25
    /// Сколько секунд после смены состояния кадры идут в корзину перехода.
    public static let transitionWindow = 1.0

    /// Период экрана по его наибольшей частоте кадров (`NSScreen.maximumFramesPerSecond`);
    /// без частоты 1/60 с.
    public static func refreshPeriod(framesPerSecond: Int) -> Double {
        framesPerSecond > 0 ? 1 / Double(framesPerSecond) : 1.0 / 60
    }

    /// Доля периода экрана в `timelineInterval`. Расписание `.animation` на macOS 26 идет сеткой
    /// 120 Гц и на экране 60 Гц: тик через 16.7 мс проходит, через 8.3 мс нет, а ровно период
    /// экрана из-за дрожания часов пропускал бы кадры. Гипотеза до замера частоты кадров на маке:
    /// если кадров заметно больше частоты экрана, поставить 1.0.
    public static let intervalSlack = 0.9

    /// Частоты кадров, которые можно выбрать в настройках («Частота кадров»).
    public static let frameRates = [30, 60]
    /// Частота кадров по умолчанию.
    public static let defaultFrameRate = 60

    /// Выбранная частота: 30 или 60; любое другое значение заменяется на `defaultFrameRate`.
    public static func normalizedFrameRate(_ rate: Int) -> Int {
        frameRates.contains(rate) ? rate : defaultFrameRate
    }

    /// Период кадров острова, с: не короче периода экрана `refreshPeriod` (без конечного
    /// положительного 1/60 с) и не короче периода выбранной частоты `frameRate`
    /// (`normalizedFrameRate`); в режиме энергосбережения не короче 1/30. Единственное место, где
    /// настройка «Частота кадров» превращается в период: от него считаются шаг `TimelineView`
    /// (`timelineInterval`), упреждение показа (`LatencyCalculator.presentationLead`) и выборка
    /// свечения, поэтому сдвиг синхронизации, подобранный на одной частоте, сохраняет смысл на
    /// другой: кадр всегда показывается на два периода позже момента отрисовки. Экран 120 Гц
    /// при 60 дает 1/60, при 30 дает 1/30; экран 60 Гц при 60 дает 1/60.
    public static func cadencePeriod(refreshPeriod: Double, frameRate: Int, lowPower: Bool) -> Double {
        let screen = refreshPeriod.isFinite && refreshPeriod > 0 ? refreshPeriod : 1.0 / 60
        let chosen = 1 / Double(normalizedFrameRate(frameRate))
        let period = max(screen, chosen)
        return lowPower ? max(period, 1.0 / 30) : period
    }

    /// Наименьший интервал `TimelineView(.animation(minimumInterval:))` острова, с:
    /// `intervalSlack` периода кадров `cadencePeriod`; в режиме энергосбережения, когда период
    /// кадров 1/30, ровно 1/30 (не больше 30 кадров). Простой (12 кадров в секунду,
    /// `RenderIdleDetector.idleInterval`) выбирает вызывающий, от частоты он не зависит.
    public static func timelineInterval(refreshPeriod: Double, lowPower: Bool, frameRate: Int = defaultFrameRate) -> Double {
        let period = cadencePeriod(refreshPeriod: refreshPeriod, frameRate: frameRate, lowPower: lowPower)
        if lowPower && period == 1.0 / 30 { return 1.0 / 30 }
        return intervalSlack * period
    }

    /// Период отрисовки для упреждения показа, с: замер `measured` (без конечного замера период
    /// экрана), но не короче периода экрана `refreshPeriod`. Кадр не показывается чаще экрана,
    /// лишние пересчеты сцены между кадрами экрана упреждение не укорачивают.
    public static func effectivePeriod(measured: Double?, refreshPeriod: Double) -> Double {
        guard let measured, measured.isFinite else { return refreshPeriod }
        return max(measured, refreshPeriod)
    }

    private struct Sample: Sendable {
        var interval: Double
        /// Шаг шкалы, может быть не конечным, если шкала дала странное значение.
        var timelineStep: Double
        var analysisFrames: Int
    }

    private struct Mark: Sendable {
        var now: Double
        var timelineTime: Double
        var sequence: UInt64
    }

    private var buckets: [RenderBucket: Ring<Sample>] = [:]
    /// Интервалы всех корзин подряд для `medianInterval(last:)`.
    private var intervals = Ring<Double>(capacity: RenderPacing.window)
    private var last: Mark?
    /// Сколько интервалов записано за все время.
    private var recorded = 0
    /// `recorded` на момент последнего `refreshedMedian`.
    private var medianRecorded: Int?

    public init() {}

    /// Кадр отрисовки в момент `now` (секунды хоста) со шкалой `timelineTime` и номером
    /// последнего кадра анализа `analysisSequence` (`FrameStore.sequence`). Интервал идет в
    /// корзину `bucket`. Не конечный момент или момент раньше прошлого и пауза длиннее `maxGap`
    /// начинают замер заново; повтор того же момента ничего не меняет.
    public mutating func record(now: Double, timelineTime: Double, bucket: RenderBucket, analysisSequence: UInt64) {
        guard now.isFinite else {
            last = nil
            return
        }
        let mark = Mark(now: now, timelineTime: timelineTime, sequence: analysisSequence)
        guard let previous = last else {
            last = mark
            return
        }
        let interval = now - previous.now
        if interval == 0 { return }
        last = mark
        guard interval > 0, interval <= Self.maxGap else { return }
        let fresh = analysisSequence >= previous.sequence ? analysisSequence - previous.sequence : 0
        let sample = Sample(
            interval: interval,
            timelineStep: timelineTime - previous.timelineTime,
            analysisFrames: Int(min(fresh, 3))
        )
        buckets[bucket, default: Ring(capacity: Self.window)].append(sample)
        intervals.append(interval)
        recorded += 1
    }

    /// Следующий кадр начинает замер заново: интервал от прошлого кадра не записывается.
    /// Записанные интервалы и медиана остаются. Нужно, пока остров в простое
    /// (`RenderIdleDetector`): редкие кадры простоя не должны попадать в замер.
    public mutating func restart() {
        last = nil
    }

    /// Забывает интервалы для медианы (`medianInterval`, `refreshedMedian`): частота кадров
    /// сменилась, интервалы старой частоты не должны давать период отрисовки. Сводки корзин
    /// (`summary`) остаются.
    public mutating func resetMedian() {
        intervals = Ring<Double>(capacity: Self.window)
        medianRecorded = nil
    }

    /// Сводка корзины при периоде экрана `refreshPeriod` (без конечного положительного 1/60 с);
    /// `nil`, если в ней нет кадров.
    public func summary(_ bucket: RenderBucket, refreshPeriod: Double) -> RenderPacingSummary? {
        guard let samples = buckets[bucket]?.elements, !samples.isEmpty else { return nil }
        let period = refreshPeriod.isFinite && refreshPeriod > 0 ? refreshPeriod : 1.0 / 60
        let count = Double(samples.count)
        let sorted = samples.map(\.interval).sorted()
        let onTime = sorted.filter { $0 < 1.5 * period }.count
        let twoOrMore = sorted.filter { $0 >= 2.5 * period }.count
        var analysis = [Double](repeating: 0, count: 4)
        for sample in samples {
            analysis[sample.analysisFrames] += 1
        }
        let steps = samples.map(\.timelineStep).filter(\.isFinite)
        let seconds = sorted.reduce(0, +)
        return RenderPacingSummary(
            frames: samples.count,
            onTime: Double(onTime) / count,
            oneMissed: Double(samples.count - onTime - twoOrMore) / count,
            twoOrMore: Double(twoOrMore) / count,
            p50Ms: Self.percentile(sorted, 0.5) * 1000,
            p95Ms: Self.percentile(sorted, 0.95) * 1000,
            maxMs: (sorted.last ?? 0) * 1000,
            intervalSigmaMs: Self.deviation(sorted) * 1000,
            timelineSigmaMs: Self.deviation(steps) * 1000,
            analysisFrames: analysis.map { $0 / count },
            framesPerSecond: seconds > 0 ? count / seconds : 0
        )
    }

    /// Медиана последних `count` интервалов всех корзин, с; `nil`, пока их меньше `count`.
    public func medianInterval(last count: Int) -> Double? {
        guard count > 0, intervals.count >= count else { return nil }
        let recent = intervals.last(count).sorted()
        let middle = count / 2
        return count.isMultiple(of: 2) ? (recent[middle - 1] + recent[middle]) / 2 : recent[middle]
    }

    /// Медиана последних `count` интервалов (`medianInterval(last:)`), пересчитанная не чаще
    /// раза в `every` новых интервалов: сортировка окна на каждом кадре не нужна. `nil`, пока
    /// интервалов меньше `count` или пересчитывать еще рано (прежнее значение в силе).
    public mutating func refreshedMedian(last count: Int, every: Int) -> Double? {
        guard intervals.count >= count else { return nil }
        if let medianRecorded, recorded - medianRecorded < every { return nil }
        medianRecorded = recorded
        return medianInterval(last: count)
    }

    /// Процентиль по ближайшему рангу в отсортированном непустом массиве.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func deviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}

/// Простой отрисовки острова: волны ровные, свечения и «вздоха» нет. Тогда кадры можно
/// рисовать реже (`idleInterval`), на картинке это не видно.
///
/// Входы на каждом кадре: наибольший уровень волн (пружины слоев и общего уровня), свечение
/// доли и пульс (сейчас «вздох»; другие пульсы передаются через наибольший из них). Вход не
/// меньше `level` (по модулю, не конечный тоже) считается ненулевым. Простой наступает, когда
/// с последнего ненулевого входа прошло `settle`, и кончается сразу на первом ненулевом.
public struct RenderIdleDetector: Sendable {
    /// Порог входа: ниже него волна неотличима от ровной линии.
    public static let level: Float = 0.01
    /// Сколько секунд все входы должны быть ниже порога до простоя.
    public static let settle = 0.5
    /// Наименьший интервал кадров в простое, с: 12 кадров в секунду.
    public static let idleInterval = 1.0 / 12

    /// Момент последнего ненулевого входа (или первого вызова), с.
    private var lastActive: Double?
    /// Результат последнего `update`.
    public private(set) var isIdle = false

    public init() {}

    /// Входы кадра в момент `now` (секунды хоста). `true`: простой. Не конечный момент ничего
    /// не меняет; момент раньше прошлого ненулевого начинает выдержку заново.
    public mutating func update(level: Float, glow: Float, pulse: Float, now: Double) -> Bool {
        guard now.isFinite else { return isIdle }
        let active = !(abs(level) < Self.level && abs(glow) < Self.level && abs(pulse) < Self.level)
        if active || lastActive.map({ now < $0 }) ?? true {
            lastActive = now
        }
        isIdle = !active && now - (lastActive ?? now) >= Self.settle
        return isIdle
    }
}

/// Кольцо последних `capacity` значений.
private struct Ring<Element: Sendable>: Sendable {
    let capacity: Int
    private var storage: [Element] = []
    /// Индекс самого старого значения, когда кольцо заполнено.
    private var start = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { storage.count }

    /// Все значения в произвольном порядке.
    var elements: [Element] { storage }

    mutating func append(_ value: Element) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[start] = value
            start = (start + 1) % capacity
        }
    }

    /// Последние `count` значений, от старых к новым.
    func last(_ count: Int) -> [Element] {
        let total = storage.count
        let n = min(max(count, 0), total)
        return (total - n..<total).map { storage[(start + $0) % total] }
    }
}
