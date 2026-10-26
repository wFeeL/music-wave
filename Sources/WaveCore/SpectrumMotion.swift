import Foundation

/// Движение полос «Спектра» во времени: по пружине на каждую из 24 полос (`BandMapper.bandCount`)
/// и призрак пика над ними.
///
/// Полосы кадра анализа почти не сглажены (атака 10 мс короче кадра 60 Гц), и линия через них
/// дрожит. Критически демпфированная пружина (`LevelSpring`, рост 45 рад/с, спад 10 рад/с:
/// половина пути вверх за 37 мс, вниз за 168 мс) убирает дрожание и не дает перелета, шаг
/// точный и от частоты кадров не зависит. Пружина, которая летит от цели (цель повернула назад),
/// сначала останавливается: перелета выше самого большого входа нет. Остановка случается на кадре,
/// поэтому на входе, который поворачивает почти каждый кадр (тарелки), ход за кадр с места
/// (около ω² dt² / 2 расстояния) зависит от частоты кадров; на постоянной цели и на ударах,
/// которые держатся дольше кадра, разница не больше одного кадра (`SpectrumMotionTests`). Призрак (`GravityRelease` с
/// нулевой атакой) стоит на линии, пока она растет или стоит, а когда она пошла вниз, держится
/// `peakHold` и падает к ней по параболе за `peakFall`: после удара над линией остается медленно
/// оседающий след. Упав на линию, призрак снова держится на ней `peakHold` (как пики
/// audioMotion). Призрак не ниже линии.
///
/// Значения в 0...1: вход ограничивается 0...1, не конечный считается нулем, недостающие полосы
/// это ноль, лишние не читаются. Пружина, дошедшая до цели ближе `restDistance` и почти без
/// скорости, встает на цель ровно, поэтому в тишине линия и призрак приходят точно в 0, и
/// детектор простоя (`RenderIdleDetector`) уходит в редкие кадры. Массивы выделяются один раз,
/// на шаге выделений нет.
public struct SpectrumMotion: Sendable {
    /// Собственная частота пружины полосы при росте и при спаде, рад/с.
    public static let riseOmega = 45.0
    public static let fallOmega = 10.0
    /// Сколько секунд призрак держится на пике и за сколько потом падает с пика до нуля.
    public static let peakHold = 0.12
    public static let peakFall = 0.6
    /// Ближе этого к цели и медленнее `restVelocity` пружина встает на цель (0.0002 pt в крыле).
    static let restDistance: Float = 1e-5
    static let restVelocity: Float = 1e-3

    private var springs: [LevelSpring]
    private var ghosts: [GravityRelease]
    /// Показанные уровни полос после пружин, 0...1.
    public private(set) var values: [Float]
    /// Призрак пика каждой полосы, 0...1, не ниже `values`.
    public private(set) var peaks: [Float]

    public init() {
        let count = BandMapper.bandCount
        springs = [LevelSpring](
            repeating: LevelSpring(riseOmega: Self.riseOmega, fallOmega: Self.fallOmega), count: count
        )
        ghosts = [GravityRelease](
            repeating: GravityRelease(attack: 0, hold: Self.peakHold, fall: Self.peakFall), count: count
        )
        values = [Float](repeating: 0, count: count)
        peaks = values
    }

    /// Наибольший показанный уровень, линия или призрак (призрак не ниже линии). Вход детектора
    /// простоя: пока он не ниже `RenderIdleDetector.level`, линия еще движется.
    public var highest: Float {
        peaks.max() ?? 0
    }

    /// Шаг к уровням полос `bands` кадра за `dt` секунд. Не конечный или не положительный `dt`
    /// ничего не меняет.
    public mutating func step(bands: [Float], dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        for band in values.indices {
            let target = Self.level(band < bands.count ? bands[band] : 0)
            let current = springs[band]
            if (target - current.value) * current.velocity < 0 {
                // Пружина летит от цели (цель повернула): она останавливается и идет назад с
                // места. Иначе скорость быстрого роста при медленном спаде (10 рад/с) уносила бы
                // линию выше любого входа.
                springs[band].reset(to: current.value)
            }
            springs[band].step(toward: target, dt: dt)
            let spring = springs[band]
            if abs(spring.value - target) <= Self.restDistance, abs(spring.velocity) <= Self.restVelocity {
                springs[band].reset(to: target)
            }
            let value = min(max(springs[band].value, 0), 1)
            values[band] = value
            // Линия дошла до призрака (поднялась к нему, стоит на месте или призрак упал на нее):
            // пик здесь, выдержка считается заново. Иначе призрак, упавший на линию, шел бы за ней
            // вниз без выдержки по старым часам.
            if value >= peaks[band] || ghosts[band].step(toward: value, dt: dt) <= value {
                ghosts[band].reset(to: value)
            }
            peaks[band] = ghosts[band].value
        }
    }

    /// Все в ноль без движения.
    public mutating func reset() {
        reset(to: [])
    }

    /// Линия и призрак встают на `bands` без движения (вход как в `step`): снимки и предпросмотр
    /// показывают заданные полосы сразу.
    public mutating func reset(to bands: [Float]) {
        for band in values.indices {
            let value = Self.level(band < bands.count ? bands[band] : 0)
            springs[band].reset(to: value)
            ghosts[band].reset(to: value)
            values[band] = value
            peaks[band] = value
        }
    }

    /// Уровень полосы в 0...1, не конечный дает 0.
    private static func level(_ raw: Float) -> Float {
        raw.isFinite ? min(max(raw, 0), 1) : 0
    }
}

/// Полосы «Спектра» одного кадра: показанные уровни после пружин (`SpectrumMotion.values`) и
/// призрак пика над ними (`SpectrumMotion.peaks`), по 24 значения 0...1.
public struct SpectrumLevels: Sendable, Equatable {
    public var values: [Float]
    public var peaks: [Float]

    public init(values: [Float], peaks: [Float]) {
        self.values = values
        self.peaks = peaks
    }
}

/// «Спектр» на кадрах острова и предпросмотра: `SpectrumMotion` идет, только пока стиль
/// «Спектр». Другой стиль сразу ставит линию и призрак в ноль без движения: новый «Спектр»
/// растет с нуля, а не с уровней, оставшихся с прошлого раза, и детектор простоя не видит старых
/// пиков (`highest` при другом стиле 0).
///
/// Полосы и пики уходят в кадр в своих массивах, а не в массивах движения. Кадр живет в SwiftUI
/// до следующего, и шаг, пишущий в массив, который кадр еще держит, копировал бы оба массива на
/// каждом кадре. Здесь два набора по очереди: шаг пишет в набор позапрошлого кадра, который к
/// этому времени уже никто не держит, поэтому запись идет на месте, без выделения памяти. Если
/// набор еще держат, запись его копирует (как новый массив), значения кадров не путаются.
public struct ShownSpectrum: Sendable {
    /// Пружины полос и призрак пика.
    public private(set) var motion = SpectrumMotion()
    /// Движение идет: прошлый шаг был со стилем «Спектр» или состояние задано `show`.
    private var active = false
    /// Набор последнего кадра записан из `motion`: кадр без шага отдает его же.
    private var published = false
    /// Какой набор отдан последним.
    private var usesSecond = false
    private var first = ShownSpectrum.zeroLevels()
    private var second = ShownSpectrum.zeroLevels()

    public init() {}

    /// Наибольший показанный уровень, линия или призрак: вход детектора простоя
    /// (`RenderIdleDetector`). При другом стиле 0.
    public var highest: Float {
        active ? motion.highest : 0
    }

    /// Снимки: линия и призрак встают в состояние `motion` без шага, следующий `step` со стилем
    /// «Спектр» отдает его.
    public mutating func show(_ motion: SpectrumMotion) {
        self.motion = motion
        active = true
        published = false
    }

    /// Предпросмотр на первом кадре: линия и призрак встают на полосы `bands` без движения
    /// (`SpectrumMotion.reset(to:)`).
    public mutating func show(bands: [Float]) {
        motion.reset(to: bands)
        active = true
        published = false
    }

    /// Кадр. Стиль «Спектр»: пружины идут к полосам `bands` за `dt` секунд, кадр получает полосы и
    /// пики. Не конечный или не положительный `dt` ничего не двигает и отдает набор прошлого
    /// кадра (повторный кадр с тем же временем). Другой стиль: линия и призрак в нуле, `nil`.
    public mutating func step(look: WaveLook, bands: [Float], dt: Double) -> SpectrumLevels? {
        guard look == .spectrum else {
            if active || published {
                motion.reset()
                active = false
                published = false
            }
            return nil
        }
        active = true
        if dt.isFinite, dt > 0 {
            motion.step(bands: bands, dt: dt)
        } else if published {
            return usesSecond ? second : first
        }
        published = true
        usesSecond.toggle()
        if usesSecond {
            Self.copy(motion, into: &second)
            return second
        }
        Self.copy(motion, into: &first)
        return first
    }

    private static func zeroLevels() -> SpectrumLevels {
        SpectrumLevels(
            values: [Float](repeating: 0, count: BandMapper.bandCount),
            peaks: [Float](repeating: 0, count: BandMapper.bandCount)
        )
    }

    private static func copy(_ motion: SpectrumMotion, into levels: inout SpectrumLevels) {
        copy(motion.values, into: &levels.values)
        copy(motion.peaks, into: &levels.peaks)
    }

    /// `source` в `target` на месте. Другая длина (не бывает) дает новый массив, тоже не общий с
    /// `source`.
    private static func copy(_ source: [Float], into target: inout [Float]) {
        guard target.count == source.count else {
            target = source.map { $0 }
            return
        }
        target.withUnsafeMutableBufferPointer { output in
            for index in output.indices {
                output[index] = source[index]
            }
        }
    }
}
