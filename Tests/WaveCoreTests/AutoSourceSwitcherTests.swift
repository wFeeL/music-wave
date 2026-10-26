import Testing
@testable import WaveCore

@Suite struct AutoSourceSwitcherTests {
    private static let yandex = "ru.yandex.desktop.music"
    private static let telegram = "org.telegram"
    private static let safari = "com.apple.Safari"
    private static let step = 0.1

    /// Подает одни и те же входы с шагом 0.1 с на отрезке [from, to] и возвращает последний ответ.
    @discardableResult
    private func run(
        _ switcher: inout AutoSourceSwitcher,
        chosen: String? = AutoSourceSwitcherTests.yandex,
        playing: String?,
        chosenPlaying: Bool,
        overridePlaying: Bool,
        from: Double,
        to: Double
    ) -> String? {
        let count = Int(((to - from) / Self.step).rounded())
        var result = switcher.override
        for i in 0...count {
            result = switcher.update(
                chosen: chosen, playing: playing, chosenPlaying: chosenPlaying,
                overridePlaying: overridePlaying, now: from + Double(i) * Self.step
            )
        }
        return result
    }

    /// Telegram играет с t=0, выбранное молчит: к t=1 переключатель уже на Telegram.
    private func switchedToTelegram() -> AutoSourceSwitcher {
        var switcher = AutoSourceSwitcher()
        run(&switcher, playing: Self.telegram, chosenPlaying: false, overridePlaying: true, from: 0, to: 1)
        return switcher
    }

    @Test func switchesAfterOneSecondOfPlay() {
        #expect(AutoSourceSwitcher.confirm == 1.0)
        var switcher = AutoSourceSwitcher()
        let early = run(&switcher, playing: Self.telegram, chosenPlaying: false, overridePlaying: false, from: 0, to: 0.9)
        #expect(early == nil)
        let confirmed = switcher.update(
            chosen: Self.yandex, playing: Self.telegram, chosenPlaying: false, overridePlaying: false, now: 1.0
        )
        #expect(confirmed == Self.telegram)
        #expect(switcher.override == Self.telegram)
    }

    /// Звук уведомления: полсекунды игры, потом снова только выбранное.
    @Test func shortBlipDoesNotSwitch() {
        var switcher = AutoSourceSwitcher()
        #expect(run(&switcher, playing: Self.telegram, chosenPlaying: true, overridePlaying: false, from: 0, to: 0.5) == nil)
        #expect(run(&switcher, playing: Self.yandex, chosenPlaying: true, overridePlaying: false, from: 0.6, to: 3) == nil)
        // Новый короткий звук не досчитывает прошлый: отсчет каждый раз с начала.
        #expect(run(&switcher, playing: Self.telegram, chosenPlaying: true, overridePlaying: false, from: 3.1, to: 3.6) == nil)
        #expect(run(&switcher, playing: nil, chosenPlaying: true, overridePlaying: false, from: 3.7, to: 6) == nil)
    }

    @Test func returnsWhenAutoSilentAndChosenPlays() {
        #expect(AutoSourceSwitcher.release == 2.0)
        var switcher = switchedToTelegram()
        #expect(run(&switcher, playing: Self.telegram, chosenPlaying: false, overridePlaying: true, from: 1.1, to: 4.9) == Self.telegram)
        let held = run(&switcher, playing: Self.yandex, chosenPlaying: true, overridePlaying: false, from: 5, to: 6.9)
        #expect(held == Self.telegram)
        let back = switcher.update(
            chosen: Self.yandex, playing: Self.yandex, chosenPlaying: true, overridePlaying: false, now: 7.0
        )
        #expect(back == nil)
        #expect(switcher.override == nil)
    }

    /// Оба молчат: остается последнее автоматическое, и выбранное, начав играть позже, сразу
    /// возвращается: тишина автоматического уже набрала `release`.
    @Test func staysWhileBothSilent() {
        var switcher = switchedToTelegram()
        #expect(run(&switcher, playing: nil, chosenPlaying: false, overridePlaying: false, from: 1.1, to: 11) == Self.telegram)
        #expect(switcher.update(
            chosen: Self.yandex, playing: Self.yandex, chosenPlaying: true, overridePlaying: false, now: 11.1
        ) == nil)
    }

    /// Оба играют, Now Playing показывает то одно, то другое: источник не скачет.
    @Test func noPingPongWhenBothPlay() {
        var switcher = switchedToTelegram()
        var now = 1.1
        while now < 11 {
            let playing = Int((now * 10).rounded()) % 7 < 3 ? Self.yandex : Self.telegram
            let result = switcher.update(
                chosen: Self.yandex, playing: playing, chosenPlaying: true, overridePlaying: true, now: now
            )
            #expect(result == Self.telegram)
            now += Self.step
        }
    }

    /// Два чужих приложения играют сразу, Now Playing мигает между ними: остается первое, пока
    /// оно не замолчит.
    @Test func noPingPongBetweenTwoAutoApps() {
        var switcher = switchedToTelegram()
        for second in 1..<10 {
            let playing = second % 2 == 0 ? Self.telegram : Self.safari
            let result = run(
                &switcher, playing: playing, chosenPlaying: false, overridePlaying: true,
                from: Double(second) + 0.1, to: Double(second) + 1
            )
            #expect(result == Self.telegram)
        }
        // Telegram замолчал, Safari играет: переход через `confirm`.
        #expect(run(&switcher, playing: Self.safari, chosenPlaying: false, overridePlaying: false, from: 10.1, to: 11) == Self.telegram)
        #expect(switcher.update(
            chosen: Self.yandex, playing: Self.safari, chosenPlaying: false, overridePlaying: false, now: 11.1
        ) == Self.safari)
    }

    /// Помощник выбранного приложения со своим bundle ID считается самим приложением.
    @Test func helperOfChosenIsChosen() {
        var switcher = AutoSourceSwitcher()
        let helper = "ru.yandex.desktop.music.helper"
        #expect(run(&switcher, playing: helper, chosenPlaying: false, overridePlaying: false, from: 0, to: 10) == nil)
        // И во время автоматического выбора он не становится новым автоматическим.
        var switched = switchedToTelegram()
        #expect(run(&switched, playing: helper, chosenPlaying: false, overridePlaying: false, from: 1.1, to: 2.5) == Self.telegram)
        // Приложение с похожим, но другим bundle ID чужое.
        var other = AutoSourceSwitcher()
        #expect(run(&other, playing: "ru.yandex.desktop.musicbox", chosenPlaying: false, overridePlaying: false, from: 0, to: 1) == "ru.yandex.desktop.musicbox")
    }

    @Test func systemWideDisables() {
        var switcher = AutoSourceSwitcher()
        #expect(run(&switcher, chosen: nil, playing: Self.telegram, chosenPlaying: false, overridePlaying: true, from: 0, to: 10) == nil)
        // Уже выбранное автоматически сбрасывается, когда пользователь выбрал весь звук системы.
        var switched = switchedToTelegram()
        #expect(switched.update(chosen: nil, playing: Self.telegram, chosenPlaying: false, overridePlaying: true, now: 1.1) == nil)
        #expect(switched.override == nil)
    }

    @Test func chosenChangeResets() {
        var switcher = switchedToTelegram()
        let other = "com.spotify.client"
        // Смена выбора сбрасывает переход, и отсчет кандидата начинается заново.
        #expect(run(&switcher, chosen: other, playing: Self.telegram, chosenPlaying: false, overridePlaying: false, from: 1.1, to: 2) == nil)
        #expect(switcher.update(
            chosen: other, playing: Self.telegram, chosenPlaying: false, overridePlaying: false, now: 2.1
        ) == Self.telegram)
        // Если пользователь выбрал само автоматическое приложение, переход не нужен.
        var picked = switchedToTelegram()
        #expect(run(&picked, chosen: Self.telegram, playing: Self.telegram, chosenPlaying: true, overridePlaying: true, from: 1.1, to: 5) == nil)
    }

    /// Цепочка A, B, C: возврат идет к A, выбору пользователя.
    @Test func chainReturnsToChosen() {
        var switcher = switchedToTelegram()
        run(&switcher, playing: Self.safari, chosenPlaying: false, overridePlaying: false, from: 1.1, to: 2.1)
        #expect(switcher.override == Self.safari)
        run(&switcher, playing: Self.yandex, chosenPlaying: true, overridePlaying: false, from: 2.2, to: 4.2)
        #expect(switcher.override == nil)
    }

    @Test func resetForgetsOverride() {
        var switcher = switchedToTelegram()
        switcher.reset()
        #expect(switcher.override == nil)
        #expect(switcher.update(
            chosen: Self.yandex, playing: Self.telegram, chosenPlaying: false, overridePlaying: false, now: 1.1
        ) == nil)
    }

    /// Выбранное играет, если Now Playing показывает его, по `isPlaying`; иначе по выводу звука.
    @Test func chosenPlayingPrefersNowPlaying() {
        let paused = NowPlayingInfo(bundleIdentifier: Self.yandex, title: "Трек", isPlaying: false)
        #expect(!AutoSourceSwitcher.appPlaying(Self.yandex, nowPlaying: paused, outputRunning: true))
        let helperPlaying = NowPlayingInfo(
            bundleIdentifier: "ru.yandex.desktop.music.helper", title: "Трек", isPlaying: true
        )
        #expect(AutoSourceSwitcher.appPlaying(Self.yandex, nowPlaying: helperPlaying, outputRunning: false))
        let other = NowPlayingInfo(bundleIdentifier: Self.telegram, title: "Голос", isPlaying: true)
        #expect(AutoSourceSwitcher.appPlaying(Self.yandex, nowPlaying: other, outputRunning: true))
        #expect(!AutoSourceSwitcher.appPlaying(Self.yandex, nowPlaying: other, outputRunning: false))
        #expect(AutoSourceSwitcher.appPlaying(Self.yandex, nowPlaying: nil, outputRunning: true))
        #expect(!AutoSourceSwitcher.appPlaying(Self.yandex, nowPlaying: nil, outputRunning: false))
    }

    /// Вывод звука не опрашивается, когда Now Playing уже знает ответ.
    @Test func appPlayingSkipsOutputWhenNowPlayingKnows() {
        let playing = NowPlayingInfo(bundleIdentifier: Self.yandex, title: "Трек", isPlaying: true)
        var asked = false
        func output() -> Bool {
            asked = true
            return false
        }
        // Вызов вне `#expect`: макрос сам вычисляет подвыражения для диагностики.
        let result = AutoSourceSwitcher.appPlaying(Self.yandex, nowPlaying: playing, outputRunning: output())
        #expect(result)
        #expect(!asked)
    }

    /// Кандидат: приложение играющей записи Now Playing, если оно не выбранное и не его помощник.
    @Test func candidateFromNowPlaying() {
        let browserTab = NowPlayingInfo(
            bundleIdentifier: "com.apple.WebKit.GPU", parentBundleIdentifier: Self.safari,
            title: "Видео", isPlaying: true
        )
        #expect(AutoSourceSwitcher.candidate(nowPlaying: browserTab, chosen: Self.yandex) == Self.safari)
        var paused = browserTab
        paused.isPlaying = false
        #expect(AutoSourceSwitcher.candidate(nowPlaying: paused, chosen: Self.yandex) == nil)
        let helper = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music.helper", title: "Трек", isPlaying: true)
        #expect(AutoSourceSwitcher.candidate(nowPlaying: helper, chosen: Self.yandex) == nil)
        #expect(AutoSourceSwitcher.candidate(nowPlaying: nil, chosen: Self.yandex) == nil)
        let empty = NowPlayingInfo(bundleIdentifier: "", title: "", isPlaying: true)
        #expect(AutoSourceSwitcher.candidate(nowPlaying: empty, chosen: Self.yandex) == nil)
    }
}
