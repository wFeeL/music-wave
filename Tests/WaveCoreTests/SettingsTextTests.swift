import Testing
@testable import WaveCore

struct SettingsTextTests {
    /// Строки «Вида», которые прячет стиль: у «Спектра» количество волн, у «Волн» след пиков.
    @Test func lookHidesUnusedRows() {
        let table: [(look: WaveLook, count: Bool, peaks: Bool)] = [(.waves, true, false), (.spectrum, false, true)]
        #expect(table.map(\.look) == WaveLook.allCases)
        for row in table {
            #expect(row.look.usesLineCount == row.count, "\(row.look): количество")
            #expect(row.look.usesSpectrumPeaks == row.peaks, "\(row.look): след пиков")
        }
    }

    /// «След пиков» показан ровно там, где он меняет линии острова и панели.
    @Test func peaksRowMatchesDrawing() {
        for look in WaveLook.allCases {
            var on = WaveAppearance.standard
            on.look = look
            on.spectrumPeaks = true
            var off = on
            off.spectrumPeaks = false
            let matters = on.lines(for: .wing) != off.lines(for: .wing) || on.lines(for: .panel) != off.lines(for: .panel)
            #expect(look.usesSpectrumPeaks == matters, "\(look): след пиков")
        }
    }

    /// Строки прячутся ровно там, где настройка не меняет рисунок: количество волн меняет линии
    /// острова только у «Волн», заливка рисуется у обоих стилей.
    @Test func hiddenRowsMatchDrawing() {
        for look in WaveLook.allCases {
            let two = WaveAppearance(
                wingWidth: 64, colorMode: .artwork, glowSize: 1, lineCount: 2, fill: 0.5, thickness: 1,
                amplitude: 1, look: look
            )
            var five = two
            five.lineCount = 5
            let countMatters = two.lines(for: .wing) != five.lines(for: .wing)
                || two.lines(for: .panel) != five.lines(for: .panel)
            #expect(look.usesLineCount == countMatters, "\(look): количество волн")
            // Заливка рисуется у обоих стилей: она добавляет работу кадру и на острове, и на панели.
            var unfilled = two
            unfilled.fill = 0
            for profile in [WaveProfile.wing, .panel] {
                #expect(two.renderCost(for: profile) > unfilled.renderCost(for: profile), "\(look) \(profile): заливка")
            }
        }
    }

    @Test func colorFlowShowsOffOrPeriod() throws {
        #expect(SettingsText.colorFlow(speed: 0) == "Выкл")
        #expect(SettingsText.colorFlow(speed: -1) == "Выкл")
        #expect(SettingsText.colorFlow(speed: .nan) == "Выкл")
        #expect(SettingsText.colorFlow(speed: 1) == "8 с")
        #expect(SettingsText.colorFlow(speed: 2) == "8 с")
        #expect(SettingsText.colorFlow(speed: 0.25) == "17 с")
        #expect(SettingsText.colorFlow(speed: 0.05) == "19,4 с")
        #expect(SettingsText.colorFlow(speed: 0.1) == "18,8 с")
        #expect(SettingsText.colorFlow(speed: 0.95) == "8,6 с")
        #expect(SettingsText.colorFlow(speed: 0.333) == "16 с")
        // Период из `PaletteFlow.period(speed:)` до десятых: текст это он же через `seconds`.
        for step in 1...20 {
            let speed = Double(step) / 20
            let period = try #require(PaletteFlow.period(speed: speed))
            #expect(SettingsText.colorFlow(speed: speed) == SettingsText.seconds((period * 10).rounded() / 10))
        }
    }

    /// Каждый шаг ползунка (0.05) показывает свой период: соседние значения не совпадают.
    @Test func colorFlowStepsAreDistinct() {
        let texts = (0...20).map { SettingsText.colorFlow(speed: Double($0) / 20) }
        #expect(Set(texts).count == texts.count, "\(texts)")
        for (left, right) in zip(texts, texts.dropFirst()) {
            #expect(left != right)
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

    @Test func flashLengthHintNamesShortAndLong() {
        #expect(SettingsText.flashLengthHint(scale: 0.5) == "Короткие вспышки")
        #expect(SettingsText.flashLengthHint(scale: 0.9) == "Короткие вспышки")
        #expect(SettingsText.flashLengthHint(scale: 1) == "Обычные вспышки")
        #expect(SettingsText.flashLengthHint(scale: 0.96) == "Обычные вспышки")
        #expect(SettingsText.flashLengthHint(scale: 1.1) == "Длинные вспышки")
        #expect(SettingsText.flashLengthHint(scale: 2) == "Длинные вспышки")
        #expect(SettingsText.flashLengthHint(scale: .nan) == "Обычные вспышки")
    }

    @Test func autoSourceCaption() {
        #expect(SettingsText.autoSource(enabled: false, current: "Safari")
            == "Волны переходят к приложению, которое начало играть")
        #expect(SettingsText.autoSource(enabled: true, current: "Safari") == "Сейчас: Safari")
    }

    /// Тексты для человека без символов, которые правила проекта запрещают: длинного тире,
    /// буквы «е» с точками и точечных разделителей.
    @Test func textsAvoidForbiddenCharacters() {
        let texts = [
            SettingsText.colorFlow(speed: 0), SettingsText.colorFlow(speed: 0.5), SettingsText.seconds(0.15),
            SettingsText.flashLengthHint(scale: 0.5), SettingsText.flashLengthHint(scale: 1),
            SettingsText.flashLengthHint(scale: 2),
            SettingsText.autoSource(enabled: false, current: "X"), SettingsText.autoSource(enabled: true, current: "X"),
        ]
        for text in texts {
            #expect(!text.contains { "\u{2014}\u{0451}\u{0401}\u{00B7}\u{2022}".contains($0) }, "\(text)")
        }
    }
}
