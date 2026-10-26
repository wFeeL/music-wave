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
}
