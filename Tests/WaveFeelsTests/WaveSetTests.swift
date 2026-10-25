import SwiftUI
import Testing
import WaveCore
@testable import WaveFeels

/// Линии одного кадра по виду волн: основные, эхо, одна и две волны, толщина, заливка, размах.
@MainActor
struct WaveSetTests {
    static let frame = WaveFrame(bands: [], layers: [0.5, 0.4, 0.3], beat: 0, level: 0.6, rawLevelDB: -20)
    static let styles: [WaveStyle] = [.wing, .panel]

    static func waves(_ change: (inout WaveAppearance) -> Void, style: WaveStyle = .wing) -> WaveSet {
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
}
