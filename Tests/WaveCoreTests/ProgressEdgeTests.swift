import Foundation
import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import WaveCore

struct ProgressEdgeTests {
    /// Полоса только у свернутого острова без баннера и при включенной функции.
    @Test func shownOnlyOnQuietCollapsedIsland() {
        let states: [IslandState] = [.hidden, .collapsed, .expanded]
        var shown = 0
        for state in states {
            for enabled in [false, true] {
                for banner in [false, true] {
                    let expected = enabled && state == .collapsed && !banner
                    let actual = ProgressEdge.isShown(enabled: enabled, state: state, banner: banner)
                    #expect(actual == expected, "\(state) enabled \(enabled) banner \(banner)")
                    if actual { shown += 1 }
                }
            }
        }
        #expect(shown == 1)
    }

    /// Полоса 1.5 pt в 1 pt от низа острова (ось Y вниз), по краям отступ на скругление низа.
    @Test func trackSitsOnTheBottomEdge() {
        #expect(ProgressEdge.height == 1.5 && ProgressEdge.bottomInset == 1 && ProgressEdge.opacity == 0.55)
        let island = CGRect(x: 100, y: 20, width: 313, height: 32)
        let track = ProgressEdge.track(island: island, sideInset: 16)
        #expect(track == CGRect(x: 116, y: 49.5, width: 281, height: 1.5))
        #expect(track.maxY == island.maxY - ProgressEdge.bottomInset)
        // Отступ шире половины острова: полоса нулевой ширины посередине, не отрицательной.
        let narrow = ProgressEdge.track(island: CGRect(x: 0, y: 0, width: 20, height: 28), sideInset: 14)
        #expect(narrow.width == 0 && narrow.midX == 10)
        // Отрицательный и не конечный отступ считается нулем.
        #expect(ProgressEdge.track(island: island, sideInset: -5).width == island.width)
        #expect(ProgressEdge.track(island: island, sideInset: .nan).width == island.width)
    }

    /// Заполненная ширина идет за долей шагами по полпикселя Retina, в пределах полосы.
    @Test func filledWidthFollowsFractionInHalfPoints() {
        #expect(ProgressEdge.step == 0.5)
        let width: CGFloat = 281
        #expect(ProgressEdge.filledWidth(fraction: 0, trackWidth: width) == 0)
        #expect(ProgressEdge.filledWidth(fraction: 0.5, trackWidth: width) == 140.5)
        #expect(ProgressEdge.filledWidth(fraction: 0.501, trackWidth: width) == 140.5)
        #expect(ProgressEdge.filledWidth(fraction: 1, trackWidth: width) == width)
        // Полная доля дает всю полосу, даже если ширина не кратна шагу.
        #expect(ProgressEdge.filledWidth(fraction: 1, trackWidth: 280.3) == 280.3)
        #expect(ProgressEdge.filledWidth(fraction: 1.7, trackWidth: width) == width)
        #expect(ProgressEdge.filledWidth(fraction: -0.2, trackWidth: width) == 0)
        #expect(ProgressEdge.filledWidth(fraction: .nan, trackWidth: width) == 0)
        #expect(ProgressEdge.filledWidth(fraction: 0.5, trackWidth: 0) == 0)
        #expect(ProgressEdge.filledWidth(fraction: 0.5, trackWidth: -3) == 0)
    }

    /// На трехминутном треке ширина меняется несколько раз в секунду, а не на каждом кадре:
    /// вид полосы с `==` перерисовывается только тогда.
    @Test func filledWidthChangesAFewTimesPerSecond() {
        let width: CGFloat = 281
        var changes = 0
        var last: CGFloat?
        for frame in 0...120 {
            let position = PlaybackPosition(elapsed: 60 + Double(frame) / 120, duration: 180)
            let filled = ProgressEdge.filledWidth(fraction: position.fraction, trackWidth: width)
            if let last, filled != last { changes += 1 }
            last = filled
        }
        #expect(changes >= 1 && changes <= 4)
    }

    /// Полоса у выреза: видимые куски слева и справа от выреза, середина под вырезом выпадает.
    /// Куски обрезаются полосой, пустые не остаются. У капсулы один кусок, вся полоса.
    @Test func visibleSegmentsSkipTheNotch() {
        let track = CGRect(x: 100, y: 49.5, width: 281, height: 1.5)
        let notch = CGRect(x: 148, y: 0, width: 185, height: 32)
        let segments = ProgressEdge.visibleSegments(track: track, notch: notch)
        #expect(segments == [
            CGRect(x: 100, y: 49.5, width: 48, height: 1.5),
            CGRect(x: 333, y: 49.5, width: 48, height: 1.5),
        ])
        #expect(ProgressEdge.visibleSegments(track: track, notch: nil) == [track])
        // Вырез сдвинут к краю: слева пусто, остается один правый кусок.
        let shifted = CGRect(x: 90, y: 0, width: 185, height: 32)
        #expect(ProgressEdge.visibleSegments(track: track, notch: shifted) == [
            CGRect(x: 275, y: 49.5, width: 106, height: 1.5),
        ])
        // Крыльев нет: полоса целиком под вырезом.
        let inside = CGRect(x: 164, y: 49.5, width: 153, height: 1.5)
        #expect(ProgressEdge.visibleSegments(track: inside, notch: notch).isEmpty)
    }

    /// Доля раскладывается по видимой длине: сначала левое крыло, затем правое.
    @Test func filledWidthsRunAcrossVisibleWings() throws {
        let track = CGRect(x: 100, y: 49.5, width: 281, height: 1.5)
        let notch = CGRect(x: 148, y: 0, width: 185, height: 32)
        let segments = ProgressEdge.visibleSegments(track: track, notch: notch)
        #expect(ProgressEdge.filledWidths(fraction: 0, segments: segments) == [0, 0])
        #expect(ProgressEdge.filledWidths(fraction: 0.25, segments: segments) == [24, 0])
        #expect(ProgressEdge.filledWidths(fraction: 0.5, segments: segments) == [48, 0])
        #expect(ProgressEdge.filledWidths(fraction: 0.75, segments: segments) == [48, 24])
        #expect(ProgressEdge.filledWidths(fraction: 1, segments: segments) == [48, 48])
        #expect(ProgressEdge.filledWidths(fraction: .nan, segments: segments) == [0, 0])
        // Шаг полпикселя по видимой длине 96 pt.
        #expect(ProgressEdge.filledWidths(fraction: 0.3, segments: segments) == [28.5, 0])
        // Крыльев нет или видимая часть короче `minVisibleLength`: полосы нет.
        let inside = CGRect(x: 164, y: 49.5, width: 153, height: 1.5)
        #expect(ProgressEdge.filledWidths(fraction: 0.5, segments: ProgressEdge.visibleSegments(track: inside, notch: notch)) == nil)
        let tiny = [CGRect(x: 0, y: 0, width: 0.5, height: 1.5), CGRect(x: 10, y: 0, width: 1, height: 1.5)]
        #expect(ProgressEdge.minVisibleLength == 2)
        #expect(ProgressEdge.filledWidths(fraction: 0.5, segments: tiny) == nil)
        // Капсула: один кусок, как `filledWidth`.
        for fraction in [0.0, 0.3, 0.501, 1] {
            #expect(
                ProgressEdge.filledWidths(fraction: fraction, segments: [track])
                    == [ProgressEdge.filledWidth(fraction: fraction, trackWidth: track.width)]
            )
        }
    }

    /// По двум крыльям 48 pt на трехминутном треке ширина меняется не чаще нескольких раз в секунду.
    @Test func filledWidthsChangeAFewTimesPerSecond() throws {
        let segments = [CGRect(x: 0, y: 0, width: 48, height: 1.5), CGRect(x: 233, y: 0, width: 48, height: 1.5)]
        var changes = 0
        var last: [CGFloat]?
        for frame in 0...120 {
            let position = PlaybackPosition(elapsed: 100 + Double(frame) / 120, duration: 180)
            let filled = try #require(ProgressEdge.filledWidths(fraction: position.fraction, segments: segments))
            if let last, filled != last { changes += 1 }
            last = filled
        }
        #expect(changes <= 2)
    }

    /// Цвет полосы округляется до 8 бит на канал: каждое значение на ступени k/255 не дальше
    /// полуступени от исходного, сдвиг меньше полуступени (переливание за кадр) цвета не меняет,
    /// сдвиг на ступень меняет. Вне 0...1 и не конечные значения не ломают цвет.
    @Test func colorIsQuantizedToEightBits() {
        let color = RGBColor(hex: 0x80_40_C8)
        let quantized = ProgressEdge.quantized(color)
        let half: Float = 0.5 / 255
        #expect(ProgressEdge.colorLevels == 255)
        for (value, original) in [(quantized.r, color.r), (quantized.g, color.g), (quantized.b, color.b)] {
            #expect(value == Float((value * 255).rounded()) / 255)
            #expect(abs(value - original) <= half)
        }
        #expect(ProgressEdge.quantized(quantized) == quantized)
        let drift = RGBColor(r: color.r + 0.0012, g: color.g - 0.0012, b: color.b + 0.0005)
        #expect(ProgressEdge.quantized(drift) == quantized)
        let step = RGBColor(r: color.r + 1.0 / 255, g: color.g, b: color.b)
        #expect(ProgressEdge.quantized(step) != quantized)
        let odd = ProgressEdge.quantized(RGBColor(r: -0.2, g: 1.3, b: .nan))
        #expect(odd == RGBColor(r: 0, g: 1, b: 0))
        // Произвольные цвета: на ступени и не дальше полуступени.
        for index in 0..<200 {
            let value = Float(index) / 199
            let result = ProgressEdge.quantized(RGBColor(r: value, g: 1 - value, b: value * value))
            #expect(abs(result.r - value) <= half + 1e-6)
            #expect(result.r == Float((result.r * 255).rounded()) / 255)
        }
    }
}
