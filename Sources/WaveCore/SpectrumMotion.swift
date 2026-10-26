import Foundation

/// Движение полос «Спектра» во времени: по пружине на каждую из 24 полос (`BandMapper.bandCount`)
/// и призрак пика над ними.
///
/// Полосы кадра анализа почти не сглажены (атака 10 мс короче кадра 60 Гц), и линия через них
/// дрожит. Критически демпфированная пружина (`LevelSpring`, рост 45 рад/с, спад 10 рад/с:
/// половина пути вверх за 37 мс, вниз за 168 мс) убирает дрожание и не дает перелета, шаг
/// точный и от частоты кадров не зависит. Пружина, которая летит от цели (цель повернула назад),
/// сначала останавливается: перелета выше самого большого входа нет. Призрак (`GravityRelease` с
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
