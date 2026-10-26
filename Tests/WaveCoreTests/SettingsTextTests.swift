import Testing
@testable import WaveCore

struct SettingsTextTests {
    /// Строки «Вида», которые прячет стиль: у «Пульса» количество, толщина, размах и заливка, у
    /// «Минимала» количество и заливка, у «Спектра» количество.
    @Test func lookHidesUnusedRows() {
        let table: [(look: WaveLook, count: Bool, fill: Bool, stroke: Bool)] = [
            (.waves, true, true, true),
            (.spectrum, false, true, true),
            (.minimal, false, false, true),
            (.pulse, false, false, false),
        ]
        #expect(table.map(\.look) == WaveLook.allCases)
        for row in table {
            #expect(row.look.usesLineCount == row.count, "\(row.look): количество")
            #expect(row.look.usesFill == row.fill, "\(row.look): заливка")
            #expect(row.look.usesStroke == row.stroke, "\(row.look): толщина и размах")
        }
    }

    /// Строки прячутся ровно там, где настройка не меняет рисунок: количество волн меняет линии
    /// острова только у «Волн», заливка рисуется только там, где `effectiveFill` ее не обнуляет.
    @Test func hiddenRowsMatchDrawing() {
        for look in WaveLook.allCases {
            let two = WaveAppearance(
                wingWidth: 64, colorMode: .artwork, glowRadius: 1, lineCount: 2, fill: 0.5, thickness: 1,
                amplitude: 1, look: look
            )
            var five = two
            five.lineCount = 5
            let countMatters = two.lines(for: .wing) != five.lines(for: .wing)
                || two.lines(for: .panel) != five.lines(for: .panel)
            #expect(look.usesLineCount == countMatters, "\(look): количество волн")
            #expect(look.usesFill == (two.effectiveFill > 0), "\(look): заливка")
        }
    }

    @Test func colorFlowShowsOffOrPeriod() throws {
        #expect(SettingsText.colorFlow(speed: 0) == "Выкл")
        #expect(SettingsText.colorFlow(speed: -1) == "Выкл")
        #expect(SettingsText.colorFlow(speed: .nan) == "Выкл")
        #expect(SettingsText.colorFlow(speed: 1) == "8 с")
        #expect(SettingsText.colorFlow(speed: 2) == "8 с")
        #expect(SettingsText.colorFlow(speed: 0.25) == "17 с")
        #expect(SettingsText.colorFlow(speed: 0.05) == "19 с")
        // Период из `PaletteFlow.period(speed:)`, до целой секунды.
        for step in 1...20 {
            let speed = Double(step) / 20
            let period = try #require(PaletteFlow.period(speed: speed))
            #expect(SettingsText.colorFlow(speed: speed) == "\(Int(period.rounded())) с")
        }
    }

    @Test func secondsUseCommaAndDropTrailingZeros() {
        #expect(SettingsText.seconds(0.15) == "0,15 с")
        #expect(SettingsText.seconds(IslandStateMachine.defaultExpandDelay) == "0,15 с")
        #expect(SettingsText.seconds(0.2) == "0,2 с")
        #expect(SettingsText.seconds(0.05) == "0,05 с")
        #expect(SettingsText.seconds(0) == "0 с")
        #expect(SettingsText.seconds(1) == "1 с")
        #expect(SettingsText.seconds(0.95) == "0,95 с")
        // Шаг ползунка 0.05 дает неточные доли: 0.15000000000000002 все равно «0,15 с».
        #expect(SettingsText.seconds(3 * 0.05) == "0,15 с")
        #expect(SettingsText.seconds(-0.1) == "0 с")
        #expect(SettingsText.seconds(.nan) == "0 с")
    }

    @Test func autoSourceCaption() {
        #expect(SettingsText.autoSource(enabled: false, current: "Safari")
            == "Волны переходят к приложению, которое начало играть")
        #expect(SettingsText.autoSource(enabled: true, current: "Safari") == "Сейчас: Safari")
    }

    @Test func pulseCaptionOnlyWithReduceMotion() {
        for look in WaveLook.allCases {
            #expect(SettingsText.lookCaption(look, reduceMotion: false) == nil)
            let caption = SettingsText.lookCaption(look, reduceMotion: true)
            #expect(caption == (look == .pulse ? "При уменьшении движения остров не дышит" : nil))
        }
    }

    /// Тексты для человека без символов, которые правила проекта запрещают: длинного тире,
    /// буквы «е» с точками и точечных разделителей.
    @Test func textsAvoidForbiddenCharacters() {
        let texts = [
            SettingsText.colorFlow(speed: 0), SettingsText.colorFlow(speed: 0.5), SettingsText.seconds(0.15),
            SettingsText.autoSource(enabled: false, current: "X"), SettingsText.autoSource(enabled: true, current: "X"),
            SettingsText.lookCaption(.pulse, reduceMotion: true) ?? "",
        ]
        for text in texts {
            #expect(!text.contains { "\u{2014}\u{0451}\u{0401}\u{00B7}\u{2022}".contains($0) }, "\(text)")
        }
    }
}
