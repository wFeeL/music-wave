import Foundation
import Testing
@testable import WaveCore

/// Цена отрисовки вида волн и облегченный вид для режима энергосбережения.
struct RenderCostTests {
    /// Набор `cpu-probe.sh --preset max`: верхние границы всех ползунков.
    static let maxPreset = WaveAppearance(
        wingWidth: 200, colorMode: .artwork, glowRadius: 3, lineCount: 6, fill: 1, thickness: 2, amplitude: 2
    )
    /// Самый тяжелый набор из замера на M2 (22.9 % ядра).
    static let audited = WaveAppearance(
        wingWidth: 200, colorMode: .artwork, glowRadius: 1.7, lineCount: 6, fill: 1, thickness: 1, amplitude: 1
    )
    static let moderate = WaveAppearance(
        wingWidth: 120, colorMode: .artwork, glowRadius: 1.5, lineCount: 4, fill: 0.3, thickness: 1, amplitude: 1
    )

    @Test func defaultsCostOne() {
        #expect(WaveAppearance.standard.renderCost == 1)
        // Цвет и размах на цену не влияют.
        var colored = WaveAppearance.standard
        colored.colorMode = .preset(.neon)
        colored.amplitude = 2
        #expect(colored.renderCost == 1)
    }

    @Test func heavyPresetsCrossTheWarningAndModerateDoesNot() {
        #expect(WaveAppearance.renderCostWarning == 2.5)
        #expect(Self.maxPreset.renderCost > WaveAppearance.renderCostWarning)
        #expect(Self.audited.renderCost > WaveAppearance.renderCostWarning)
        #expect(Self.moderate.renderCost < WaveAppearance.renderCostWarning)
        #expect(!WaveAppearance.standard.isRenderCostHigh)
        #expect(!Self.moderate.isRenderCostHigh)
        #expect(Self.maxPreset.isRenderCostHigh)
        // Ни один ползунок в одиночку подсказку не включает.
        for single in [
            Self.changed { $0.lineCount = 6 }, Self.changed { $0.fill = 1 }, Self.changed { $0.glowRadius = 3 },
            Self.changed { $0.wingWidth = 200 }, Self.changed { $0.thickness = 2 },
        ] {
            #expect(single.renderCost > 1)
            #expect(single.renderCost < WaveAppearance.renderCostWarning)
        }
    }

    /// Цена не убывает ни по одному ползунку, остальные на любом из трех уровней.
    @Test func costIsMonotonicInEachKnob() {
        let bases = [WaveAppearance.standard, Self.moderate, Self.maxPreset]
        let knobs: [(String, [(inout WaveAppearance) -> Void])] = [
            ("lines", (1...6).map { count in { $0.lineCount = count } }),
            ("fill", stride(from: 0.0, through: 1, by: 0.05).map { value in { $0.fill = value } }),
            ("radius", stride(from: 0.5, through: 3, by: 0.1).map { value in { $0.glowRadius = value } }),
            ("wings", stride(from: 40.0, through: 200, by: 8).map { value in { $0.wingWidth = value } }),
            ("thickness", stride(from: 0.5, through: 2, by: 0.1).map { value in { $0.thickness = value } }),
        ]
        for base in bases {
            for (name, steps) in knobs {
                let costs = steps.map { step -> Double in
                    var appearance = base
                    step(&appearance)
                    return appearance.renderCost
                }
                #expect(zip(costs, costs.dropFirst()).allSatisfy { $0 <= $1 }, "\(name): \(costs)")
                #expect(costs.last! > costs.first!, "\(name) must matter")
            }
        }
    }

    @Test func glowLinesAreMainBassAndMid() {
        #expect(WaveLine.lines(count: 1).map(\.glows) == [true])
        #expect(WaveLine.lines(count: 2).map(\.glows) == [true, false])
        #expect(WaveLine.lines(count: 6).map(\.glows) == [true, true, false, false, false, false])
    }

    /// Энергосбережение: эхо уходит (больше трех линий рисуются тремя), свечения линий нет,
    /// остальное как в настройках.
    @Test func lightenedDropsEchoesAndGlowPass() {
        let custom = WaveAppearance(
            wingWidth: 180, colorMode: .custom(RGBColor(hex: 0x7A5CFF)), glowRadius: 2.5, lineCount: 6, fill: 0.4,
            thickness: 1.5, amplitude: 1.8
        )
        #expect(custom.glowPass)
        let light = custom.lightened()
        #expect(light.lineCount == 3)
        #expect(!light.glowPass)
        #expect(light.lines == WaveLine.lines(count: 3))
        #expect(light.wingWidth == 180 && light.colorMode == custom.colorMode && light.glowRadius == 2.5)
        #expect(light.fill == 0.4 && light.thickness == 1.5 && light.amplitude == 1.8)
        #expect(light.renderCost < custom.renderCost)
        // Три линии и меньше остаются как есть.
        for count in 1...3 {
            let few = Self.changed { $0.lineCount = count }
            #expect(few.lightened().lineCount == count)
            #expect(few.lightened().lines == few.lines)
        }
        // Повторное облегчение ничего не меняет, исходный вид не тронут.
        #expect(light.lightened() == light)
        #expect(custom.lineCount == 6 && custom.glowPass)
        // Без прохода свечения цена не зависит от радиуса.
        var wide = light
        wide.glowRadius = 3
        #expect(wide.renderCost == light.renderCost)
    }

    /// Каждый стиль на тех же настройках стоит не больше «Волн»: и на свернутом острове (`.wing`),
    /// и в раскрытой панели (`.panel`), со свечением и без него.
    @Test func everyLookCostsNoMoreThanWaves() {
        var checked = 0
        for lineCount in 1...6 {
            for fill in [0.0, 1] {
                for thickness in [0.5, 2] {
                    for radius in [0.5, 3] {
                        for wing in [64.0, 200] {
                            let base = WaveAppearance(
                                wingWidth: wing, colorMode: .artwork, glowRadius: radius, lineCount: lineCount,
                                fill: fill, thickness: thickness, amplitude: 1
                            )
                            for appearance in [base, base.lightened()] {
                                for profile in WaveProfile.allCases {
                                    let waves = appearance.renderCost(for: profile)
                                    for look in WaveLook.allCases {
                                        var styled = appearance
                                        styled.look = look
                                        let cost = styled.renderCost(for: profile)
                                        #expect(cost > 0, "\(look) \(profile)")
                                        #expect(
                                            cost <= waves + 1e-9,
                                            "\(look) \(profile) lines \(lineCount) fill \(fill) thickness \(thickness) radius \(radius) wing \(wing) glow \(appearance.glowPass): \(cost) > \(waves)"
                                        )
                                        checked += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 6 * 2 * 2 * 2 * 2 * 2 * 2 * 4)
    }

    /// Цена стилей по модели: «Волны» не изменились, остальные считаются от своих линий.
    @Test func lookCostsFollowTheModel() {
        var appearance = WaveAppearance.standard
        #expect(appearance.renderCost(for: .wing) == appearance.renderCost)
        #expect(appearance.renderCost(for: .panel) == 1)
        // «Спектр» стоит как одна волна общего уровня.
        var one = appearance
        one.lineCount = 1
        appearance.look = .spectrum
        for profile in WaveProfile.allCases {
            #expect(abs(appearance.renderCost(for: profile) - one.renderCost(for: profile)) < 1e-12)
        }
        // «Минимал»: одна линия с толщиной × 0.6, со свечением, без заливки.
        appearance.look = .minimal
        appearance.fill = 1
        let stroke = 0.75 + 0.25 * WaveLook.minimalWidthScale
        #expect(abs(appearance.renderCost - stroke * 2 / 5) < 1e-12)
        // «Пульс»: в крыле только «вздох» тела, в панели одна стоячая линия без свечения и заливки.
        appearance.look = .pulse
        appearance.wingWidth = 200
        let span = 0.75 + 0.25 * 200 / 64
        #expect(abs(appearance.renderCost(for: .wing) - 0.25 * span / 5) < 1e-12)
        #expect(abs(appearance.renderCost(for: .panel) - 1.0 / 5) < 1e-12)
        #expect(appearance.renderCost == appearance.renderCost(for: .wing))
    }

    /// Проход свечения не сохраняется: в настройках его нет, прочитанный вид всегда со свечением.
    @Test func glowPassIsNotStored() throws {
        let light = Self.maxPreset.lightened()
        let data = try JSONEncoder().encode(light)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("glowPass"))
        let decoded = try JSONDecoder().decode(WaveAppearance.self, from: data)
        #expect(decoded.glowPass)
        #expect(decoded.lineCount == 3)
    }

    private static func changed(_ change: (inout WaveAppearance) -> Void) -> WaveAppearance {
        var appearance = WaveAppearance.standard
        change(&appearance)
        return appearance
    }
}
