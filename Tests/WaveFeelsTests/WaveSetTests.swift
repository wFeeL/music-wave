import SwiftUI
import Testing
import WaveCore
@testable import WaveFeels

/// Линии одного кадра по виду волн: основные, эхо, одна и две волны, толщина, заливка, размах.
@MainActor
struct WaveSetTests {
    static let frame = WaveFrame(bands: [], layers: [0.5, 0.4, 0.3], beat: 0, level: 0.6, rawLevelDB: -20)
    /// Кадр с уровнями 24 полос: от баса к верху спадают, с горбом на середине.
    static let bandFrame = WaveFrame(
        bands: (0..<24).map { band -> Float in
            let x = Float(band) / 23
            let hump: Float = 0.3 * (1 - abs(2 * x - 1))
            let slope: Float = 0.8 - 0.6 * x
            return min(max(slope + hump, 0), 1)
        },
        layers: [0.5, 0.4, 0.3], beat: 0, level: 0.6, rawLevelDB: -20
    )
    static let styles: [WaveStyle] = [.wing, .panel]

    static func waves(
        _ change: (inout WaveAppearance) -> Void, style: WaveStyle = .wing, frame: WaveFrame = WaveSetTests.frame
    ) -> WaveSet {
        var appearance = WaveAppearance.standard
        change(&appearance)
        return WaveSet(
            frame: frame, palette: PaletteExtractor.fallback, motion: WaveMotion(), time: 1, style: style,
            appearance: appearance
        )
    }

    /// Шесть волн: основные бас, середина, верх и их эхо с размахом × 0.72 / 0.52 / 0.38,
    /// прозрачностью × 0.45 / 0.3 / 0.28 и фазой, сдвинутой на 0.6 рад. Свечение только у
    /// основных баса и середины.
    @Test func echoesScaleLevelAndOpacity() {
        let scales: [Float] = [0.72, 0.52, 0.38]
        let opacities: [Float] = [0.45, 0.3, 0.28]
        for style in Self.styles {
            let waves = Self.waves({ $0.lineCount = 6 }, style: style)
            #expect(waves.layers.map(\.shape) == [.bass, .mid, .high, .bass, .mid, .high])
            #expect(waves.layers.map(\.glows) == [true, true, false, false, false, false])
            for index in 0..<3 {
                let main = waves.layers[index]
                let echo = waves.layers[index + 3]
                #expect(main.level == Self.frame.layers[index])
                #expect(abs(echo.level - Self.frame.layers[index] * scales[index]) < 1e-6)
                #expect(main.stops.count == echo.stops.count)
                for (mainStop, echoStop) in zip(main.stops, echo.stops) {
                    #expect(echoStop.color == mainStop.color)
                    #expect(echoStop.location == mainStop.location)
                    #expect(abs(echoStop.opacity - mainStop.opacity * opacities[index]) < 1e-6)
                }
                let phase = WaveMotion().phase(echo.shape, profile: style.profile).shifted(by: 0.6)
                #expect(Array(echo.samples) == WaveShape.samples(
                    layer: echo.shape, amplitude: echo.level, phase: phase, count: echo.samples.count,
                    profile: style.profile
                ))
            }
        }
    }

    /// Эхо середины и верха в крыле на 32 точках, эхо баса и все линии панели с полным числом
    /// точек. Эхо делит набор точек градиента со своей основной линией, все точки линий лежат
    /// в одном массиве набора подряд.
    @Test func echoesShareStopsAndThinOutInTheWing() {
        let wing = Self.waves({ $0.lineCount = 6 }, style: .wing)
        #expect(wing.layers.map(\.samples.count) == [64, 64, 64, 64, 32, 32])
        #expect(wing.layers.map(\.stopSet) == [0, 1, 2, 0, 1, 2])
        #expect(wing.layers.map(\.opacity) == [1, 1, 1, 0.45, 0.3, 0.28])
        var next = 0
        for layer in wing.layers {
            #expect(layer.samples.startIndex == next)
            next = layer.samples.endIndex
        }
        for index in 0..<3 {
            #expect(wing.layers[index].baseStops == wing.layers[index + 3].baseStops)
            #expect(wing.layers[index].stops == Array(wing.layers[index].baseStops))
        }
        let panel = Self.waves({ $0.lineCount = 6 }, style: .panel)
        #expect(panel.layers.map(\.samples.count) == [Int](repeating: WaveSet.panelPoints, count: 6))
        // Точки и цвета те же, что у прежнего расчета по линии.
        for layer in wing.layers + panel.layers {
            let style: WaveStyle = layer.samples.count == WaveSet.panelPoints ? .panel : .wing
            let locations = style == .wing ? WaveSet.wingLocations : WaveSet.panelLocations
            #expect(Array(layer.baseStops) == WavePaint.stops(
                palette: PaletteExtractor.fallback, layer: layer.shape, level: Self.frame.layers[layer.shape.rawValue],
                time: 1, locations: locations, profile: style.profile
            ))
        }
    }

    /// Градиенты строятся в наборе, один на кадр для всех холстов: обводка у каждой линии из ее
    /// `stops`, заливка по набору точек градиента с прозрачностью `fillTopOpacity × fill` (у
    /// основной линии и эха один). Без заливки градиентов заливки нет.
    @Test func gradientsAreBuiltOncePerSet() {
        for style in Self.styles {
            let waves = Self.waves({
                $0.lineCount = 6
                $0.fill = 0.5
            }, style: style)
            let top = min(Double(WavePaint.fillTopOpacity) * 0.5, 1)
            #expect(waves.fillGradients.count == 3)
            for layer in waves.layers {
                let opacity = layer.opacity
                let stroke = WaveSet.gradient(layer.baseStops) { Double($0 * opacity) }
                let fill = WaveSet.gradient(layer.baseStops) { _ in top }
                #expect(layer.gradient == stroke)
                #expect(layer.gradient.stops.map(\.location) == layer.stops.map { CGFloat($0.location) })
                #expect(waves.fillGradients[layer.stopSet] == fill)
            }
            #expect(Self.waves({ $0.lineCount = 6 }, style: style).fillGradients.isEmpty)
            #expect(WaveSet(empty: style).fillGradients.isEmpty)
        }
    }

    /// Одна волна показывает общий уровень формой середины, со свечением.
    @Test func oneLineShowsOverallLevel() {
        for style in Self.styles {
            let waves = Self.waves({ $0.lineCount = 1 }, style: style)
            #expect(waves.layers.count == 1)
            #expect(waves.layers.first?.shape == .mid)
            #expect(waves.layers.first?.level == Self.frame.level)
            #expect(waves.layers.first?.glows == true)
        }
    }

    /// Две волны: бас и верх от своих уровней; свечение только у баса.
    @Test func twoLinesAreBassAndHigh() {
        let waves = Self.waves { $0.lineCount = 2 }
        #expect(waves.layers.map(\.shape) == [.bass, .high])
        #expect(waves.layers.map(\.level) == [0.5, 0.3])
        #expect(waves.layers.map(\.glows) == [true, false])
    }

    /// По умолчанию три основные волны; толщина и заливка идут в набор, «Размах» в точки.
    @Test func appearanceCarriesThicknessFillAndGain() {
        let standard = Self.waves { _ in }
        #expect(standard.layers.map(\.shape) == [.bass, .mid, .high])
        #expect(standard.thickness == 1)
        #expect(standard.fill == 0)

        let styled = Self.waves {
            $0.thickness = 2
            $0.fill = 0.5
            $0.amplitude = 2
        }
        #expect(styled.thickness == 2)
        #expect(styled.fill == 0.5)
        let bass = styled.layers[0]
        #expect(Array(bass.samples) == WaveShape.samples(
            layer: .bass, amplitude: bass.level, phase: WaveMotion().phase(.bass, profile: .wing),
            count: bass.samples.count, profile: .wing, gain: 2
        ))
        #expect(bass.samples != standard.layers[0].samples)

        let empty = WaveSet(empty: .panel)
        #expect(empty.layers.isEmpty)
        #expect(empty.fill == 0)
    }

    // MARK: - Стили, цвет по частотам, опции экрана

    /// Набор по умолчанию строится так же, как до стилей: три основные линии с точками и цветами
    /// прежнего расчета, без заливки, с геометрией `.standard`.
    @Test func defaultSetUnchanged() {
        for style in Self.styles {
            let waves = Self.waves({ _ in }, style: style)
            #expect(waves.geometry == .standard)
            #expect(waves.fill == 0)
            #expect(waves.thickness == 1)
            #expect(waves.fillGradients.isEmpty)
            #expect(waves.layers.map(\.shape) == [.bass, .mid, .high])
            let locations = style == .wing ? WaveSet.wingLocations : WaveSet.panelLocations
            for layer in waves.layers {
                let level = Self.frame.layers[layer.shape.rawValue]
                #expect(layer.level == level)
                #expect(Array(layer.baseStops) == WavePaint.stops(
                    palette: PaletteExtractor.fallback, layer: layer.shape, level: level, time: 1,
                    locations: locations, profile: style.profile
                ))
                #expect(Array(layer.samples) == WaveShape.samples(
                    layer: layer.shape, amplitude: level, phase: WaveMotion().phase(layer.shape, profile: style.profile),
                    count: layer.samples.count, profile: style.profile
                ))
            }
        }
        #expect(WaveSet(empty: .wing).geometry == .standard)
    }

    /// «Спектр»: одна линия формы середины через уровни полос (`SpectrumShape`), цвет от общего
    /// уровня, со свечением, во всю ширину крыла или панели.
    @Test func spectrumSetHasOneLine() {
        for style in Self.styles {
            let waves = Self.waves({ $0.look = .spectrum }, style: style, frame: Self.bandFrame)
            #expect(waves.layers.count == 1)
            let line = waves.layers[0]
            #expect(line.shape == .mid)
            #expect(line.level == Self.bandFrame.level)
            #expect(line.glows)
            let count = style == .wing ? WaveSet.wingPoints : WaveSet.panelPoints
            var expected = [Float](repeating: -1, count: count)
            expected.withUnsafeMutableBufferPointer {
                SpectrumShape.samples(bands: Self.bandFrame.bands, count: count, profile: style.profile, gain: 1, into: $0)
            }
            #expect(Array(line.samples) == expected)
            // Линия стоит на нижней базовой линии: y без знака.
            #expect(line.samples.allSatisfy { $0 >= 0 })
            // В тишине полос линия лежит на базовой линии.
            let flat = Self.waves({ $0.look = .spectrum }, style: style)
            #expect(flat.layers.count == 1)
            #expect(flat.layers[0].samples.allSatisfy { $0 == 0 })
        }
    }

    /// «Спектр» рисуется от нижней базовой линии с обычной толщиной, заливка из настроек.
    @Test func spectrumSetGeometryIsBottom() {
        for style in Self.styles {
            let waves = Self.waves({
                $0.look = .spectrum
                $0.fill = 0.5
            }, style: style)
            #expect(waves.geometry.baseline == .bottom)
            #expect(waves.geometry.widthScale == 1)
            #expect(waves.fill == 0.5)
            #expect(waves.fillGradients.count == 1)
        }
    }

    /// «Пульс»: в крыле линий нет вовсе (ни заливки, ни градиентов), в панели одна стоячая линия
    /// общего уровня с нулевой фазой, без свечения и заливки.
    @Test func pulseWingSetIsEmpty() {
        let wing = Self.waves({
            $0.look = .pulse
            $0.fill = 0.5
        }, style: .wing)
        #expect(wing.layers.isEmpty)
        #expect(wing.fill == 0)
        #expect(wing.fillGradients.isEmpty)
        #expect(wing.geometry == .standard)

        var motion = WaveMotion()
        motion.advance(layers: [0.5, 0.4, 0.3], dt: 0.5)
        var appearance = WaveAppearance.standard
        appearance.look = .pulse
        let panel = WaveSet(
            frame: Self.frame, palette: PaletteExtractor.fallback, motion: motion, time: 1, style: .panel,
            appearance: appearance
        )
        #expect(panel.layers.count == 1)
        let line = panel.layers[0]
        #expect(line.shape == .mid)
        #expect(line.level == Self.frame.level)
        #expect(!line.glows)
        #expect(panel.fill == 0)
        #expect(Array(line.samples) == WaveShape.samples(
            layer: .mid, amplitude: Self.frame.level, phase: WavePhase(carrier: 0, harmonic: 0),
            count: WaveSet.panelPoints, profile: .panel
        ))
    }

    /// «Пульс» не строит наборы и слои свернутого острова: ни крыльев у выреза, ни линии капсулы, ни
    /// волн баннера (`collapsed == false`). Набор панели только у раскрытой панели. Остальные стили
    /// решают как раньше, слои свернутого острова у них есть.
    @Test func pulseBuildsNoCollapsedSets() {
        for collapsedStyle in Self.styles {
            for panelLayer in [false, true] {
                let sets = IslandWavesView.neededSets(
                    look: .pulse, wings: true, panelLayer: panelLayer, bannerLayer: true, collapsedStyle: collapsedStyle
                )
                #expect(sets.wing == false)
                #expect(sets.panel == panelLayer)
                #expect(sets.collapsed == false)
            }
        }
        for look in [WaveLook.waves, .spectrum, .minimal] {
            let notch = IslandWavesView.neededSets(
                look: look, wings: true, panelLayer: false, bannerLayer: false, collapsedStyle: .wing
            )
            #expect(notch.wing && !notch.panel)
            let pill = IslandWavesView.neededSets(
                look: look, wings: true, panelLayer: false, bannerLayer: false, collapsedStyle: .panel
            )
            #expect(!pill.wing && pill.panel)
            let banner = IslandWavesView.neededSets(
                look: look, wings: false, panelLayer: false, bannerLayer: true, collapsedStyle: .panel
            )
            #expect(banner.wing && !banner.panel)
            let expanded = IslandWavesView.neededSets(
                look: look, wings: false, panelLayer: true, bannerLayer: false, collapsedStyle: .wing
            )
            #expect(!expanded.wing && expanded.panel)
            #expect(notch.collapsed && pill.collapsed && banner.collapsed && expanded.collapsed)
        }
    }

    /// Точка удара у выреза стоит там, где начинается линия: у середины крыла, у «Спектра» на
    /// нижней базовой линии холста.
    @Test func accentSitsOnTheBaseline() {
        let wing = CGRect(x: 100, y: 40, width: 64, height: 32)
        #expect(IslandWavesView.accentY(in: wing, baseline: .center) == wing.midY)
        #expect(IslandWavesView.accentY(in: wing, baseline: .bottom) == wing.maxY - WaveDrawing.wingEdgeMargin)
        #expect(IslandWavesView.accentY(in: wing, baseline: .bottom) == 66)
        var spectrum = WaveAppearance.standard
        spectrum.look = .spectrum
        #expect(spectrum.lookGeometry.baseline == .bottom)
        #expect(WaveAppearance.standard.lookGeometry.baseline == .center)
    }

    /// «Минимал»: одна тонкая линия общего уровня, без заливки при любой «Заливке» в настройках.
    @Test func minimalHasNoFill() {
        for style in Self.styles {
            let waves = Self.waves({
                $0.look = .minimal
                $0.fill = 1
                $0.lineCount = 6
            }, style: style)
            #expect(waves.fill == 0)
            #expect(waves.fillGradients.isEmpty)
            #expect(waves.layers.count == 1)
            #expect(waves.layers.first?.shape == .mid)
            #expect(waves.layers.first?.level == Self.frame.level)
            #expect(waves.geometry == WaveLookGeometry(baseline: .center, widthScale: WaveLook.minimalWidthScale))
        }
    }

    /// Цвет по частотам: одна линия красится участками (`sectionStops`) на точках с краями
    /// смешения, линии слоев своим цветом на обычных точках.
    @Test func colorByBandPaintsOneLineBySections() {
        for style in Self.styles {
            let sectionLocations = style == .wing ? WaveSet.wingSectionLocations : WaveSet.panelSectionLocations
            let locations = style == .wing ? WaveSet.wingLocations : WaveSet.panelLocations
            let options = WavePaint.Options(colorByBand: true)
            for look in [WaveLook.waves, .spectrum, .minimal] {
                let waves = Self.waves({
                    $0.look = look
                    $0.lineCount = 1
                    $0.colorByBand = true
                }, style: style)
                #expect(waves.layers.count == 1)
                var expected = [WavePaint.Stop](
                    repeating: WavePaint.Stop(location: 0, color: PaletteColor(r: 0, g: 0, b: 0), opacity: 0),
                    count: sectionLocations.count
                )
                expected.withUnsafeMutableBufferPointer {
                    WavePaint.sectionStops(
                        palette: PaletteExtractor.fallback, level: Self.frame.level, time: 1, locations: sectionLocations,
                        profile: style.profile, options: options, into: $0
                    )
                }
                #expect(Array(waves.layers[0].baseStops) == expected)
            }
            let layered = Self.waves({ $0.colorByBand = true }, style: style)
            for layer in layered.layers {
                #expect(Array(layer.baseStops) == WavePaint.stops(
                    palette: PaletteExtractor.fallback, layer: layer.shape, level: Self.frame.layers[layer.shape.rawValue],
                    time: 1, locations: locations, profile: style.profile, options: options
                ))
            }
        }
    }

    /// Опции экрана доходят до рисования: «Увеличить контраст» дает толщину × 1.4 и контрастные
    /// цвета, переливание идет фазой в цвета.
    @Test func contrastAndFlowReachPaint() {
        let contrast = WaveAppearance.standard.adapted(to: DisplayOptions(increaseContrast: true))
        let waves = WaveSet(
            frame: Self.frame, palette: PaletteExtractor.fallback, motion: WaveMotion(), time: 1, style: .wing,
            appearance: contrast, flowPhase: 0.3
        )
        #expect(waves.geometry.widthScale == WaveAppearance.contrastWidthScale)
        for layer in waves.layers {
            #expect(Array(layer.baseStops) == WavePaint.stops(
                palette: PaletteExtractor.fallback, layer: layer.shape, level: Self.frame.layers[layer.shape.rawValue],
                time: 1, locations: WaveSet.wingLocations, profile: .wing,
                options: WavePaint.Options(highContrast: true, flowPhase: 0.3)
            ))
        }
    }

    /// «Пульс» дышит без «Вздоха на битах» и у свернутого острова светится громкостью; у раскрытой
    /// панели и баннера свечение доли, как у остальных стилей. Остальные стили как раньше.
    @Test func pulseBreathesWithoutBeatPulse() {
        let visuals = IslandVisuals(
            frame: Self.frame, sampled: Self.frame, motion: WaveMotion(), palette: PaletteExtractor.fallback,
            glow: 0, pulse: 0.5, ambient: 0, time: 1
        )
        let level = Self.frame.level
        let pulse = IslandView.breathing(
            look: .pulse, visuals: visuals, collapsed: true, canBreathe: true, beatPulse: false
        )
        let breath = PulseLook.breath(pulse: 0.5, ambient: 0, level: level)
        #expect(pulse.scale == 1 + CGFloat(PulseLook.breathDepth) * CGFloat(breath))
        #expect(pulse.glow == PulseLook.glow(glow: 0, ambient: 0, level: level))
        #expect(pulse.glow > 0)
        let expanded = IslandView.breathing(
            look: .pulse, visuals: visuals, collapsed: false, canBreathe: false, beatPulse: true
        )
        #expect(expanded.scale == 1)
        #expect(expanded.glow == visuals.glow)

        let waves = IslandView.breathing(
            look: .waves, visuals: visuals, collapsed: true, canBreathe: true, beatPulse: true
        )
        #expect(waves.scale == 1 + IslandView.breathDepth * 0.5)
        #expect(waves.glow == 0)
        let still = IslandView.breathing(
            look: .waves, visuals: visuals, collapsed: true, canBreathe: true, beatPulse: false
        )
        #expect(still.scale == 1)
    }
}
