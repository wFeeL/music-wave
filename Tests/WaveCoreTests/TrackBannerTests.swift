import Testing
@testable import WaveCore

struct TrackBannerTests {
    private static let a = TrackKey(title: "Первый", artist: "Исполнитель", source: "com.apple.Music")
    private static let b = TrackKey(title: "Второй", artist: "Исполнитель", source: "com.apple.Music")
    private static let c = TrackKey(title: "Третий", artist: "Исполнитель", source: "com.apple.Music")
    private static let d = TrackKey(title: "Четвертый", artist: "Исполнитель", source: "com.apple.Music")
    private static let e = TrackKey(title: "Пятый", artist: "Исполнитель", source: "com.apple.Music")

    private func inputs(
        _ track: TrackKey?, playing: Bool = true, enabled: Bool = true,
        panelOpen: Bool = false, suppressed: Bool = false
    ) -> TrackBannerInputs {
        TrackBannerInputs(
            enabled: enabled, track: track, isPlaying: playing, panelOpen: panelOpen, suppressed: suppressed
        )
    }

    /// Баннер с базовым треком A, обновленный в момент 0.
    private func withBaseline() -> TrackBanner {
        var banner = TrackBanner()
        _ = banner.update(inputs(Self.a), now: 0)
        return banner
    }

    private func isShowing(_ phase: TrackBannerPhase) -> Bool {
        if case .showing = phase { return true }
        return false
    }

    @Test func firstTrackAfterResetIsBaseline() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 0.5)
        banner.reset()
        var now = 1.0
        while now <= 20 {
            #expect(banner.update(inputs(Self.a), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
        #expect(banner.deadline == nil)
    }

    @Test func newTrackShowsAfterSettle() {
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 10.29) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 10.31) == .showing(Self.b, textVisible: true))
        #expect(banner.update(inputs(Self.b), now: 13.67) == .showing(Self.b, textVisible: true))
        #expect(banner.update(inputs(Self.b), now: 13.69) == .showing(Self.b, textVisible: false))
        #expect(banner.update(inputs(Self.b), now: 13.79) == .showing(Self.b, textVisible: false))
        #expect(banner.update(inputs(Self.b), now: 13.81) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 30) == .hidden)
    }

    @Test func rapidChangesUpdateOneBanner() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        _ = banner.update(inputs(Self.c), now: 10.1)
        var now = 10.1
        while now < 10.39 {
            let phase = banner.update(inputs(Self.c), now: now)
            #expect(phase == .hidden, "t \(now)")
            now += 0.02
        }
        #expect(banner.update(inputs(Self.c), now: 10.41) == .showing(Self.c, textVisible: true))
        // Смена во время показа обновляет содержимое после своей выдержки и продлевает показ.
        #expect(banner.update(inputs(Self.d), now: 11) == .showing(Self.c, textVisible: true))
        #expect(banner.update(inputs(Self.d), now: 11.29) == .showing(Self.c, textVisible: true))
        #expect(banner.update(inputs(Self.d), now: 11.31) == .showing(Self.d, textVisible: true))
        #expect(banner.update(inputs(Self.d), now: 14.79) == .showing(Self.d, textVisible: false))
        #expect(banner.update(inputs(Self.d), now: 14.81) == .hidden)
    }

    @Test func waitsOneSecondAfterHide() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(banner.update(inputs(Self.b), now: 13.81) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.0) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.3) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.79) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.81) == .showing(Self.e, textVisible: true))
    }

    @Test func gapCountsFromHideEvenWithoutUpdateAtHide() {
        // Показ кончился в 13.8, а следующий вызов только в 14.0 со сменой трека.
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(banner.update(inputs(Self.e), now: 14.0) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.79) == .hidden)
        #expect(isShowing(banner.update(inputs(Self.e), now: 14.81)))
    }

    @Test func pausedChangeShowsWhenPlaybackStarts() {
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b, playing: false), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b, playing: false), now: 15) == .hidden)
        #expect(banner.deadline == nil)
        #expect(banner.update(inputs(Self.b), now: 20) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 20.29) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 20.31) == .showing(Self.b, textVisible: true))
    }

    @Test func pauseDuringSettleDropsPendingChange() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(banner.update(inputs(Self.b, playing: false), now: 10.1) == .hidden)
        #expect(banner.update(inputs(Self.b, playing: false), now: 10.5) == .hidden)
        // Воспроизведение снова: выдержка заново от 11.
        #expect(banner.update(inputs(Self.b), now: 11) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 11.29) == .hidden)
        #expect(isShowing(banner.update(inputs(Self.b), now: 11.31)))
    }

    @Test func returnToBaselineDuringSettleShowsNothing() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(banner.update(inputs(Self.a), now: 10.1) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 11) == .hidden)
        #expect(banner.deadline == nil)
    }

    @Test func emptyTitleNeverShows() {
        var banner = withBaseline()
        let empty = TrackKey(title: "", artist: "Исполнитель", source: "com.apple.Music")
        let blank = TrackKey(title: "  ", artist: "Другой", source: "com.apple.Music")
        for (index, key) in [empty, blank].enumerated() {
            let start = 10.0 + Double(index) * 10
            var now = start
            while now < start + 5 {
                #expect(banner.update(inputs(key), now: now) == .hidden, "t \(now)")
                now += 0.25
            }
        }
        #expect(banner.update(inputs(nil), now: 30) == .hidden)
        // Пустое название не стало базовым: возврат к A без баннера.
        #expect(banner.update(inputs(Self.a), now: 31) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 32) == .hidden)
    }

    /// Записи Now Playing идут через `NowPlayingHold`, как в адаптере (шаг 0,1 с). A, пустой
    /// снимок, A: баннера нет ни при коротком пропуске, ни после истечения удержания.
    /// A, пустой, B: баннер один раз и с B. Короткий пропуск до баннера доходит треком,
    /// длинный пустым.
    @Test func emptyGapBetweenTracksShowsOnlyNewTrack() {
        for gapSteps in [3, 50] {
            for next in [Self.a, Self.b] {
                var hold = NowPlayingHold<TrackKey>()
                var banner = TrackBanner()
                var holdUntil: Double?
                var published: TrackKey?
                var sawNil = false
                var shown: [TrackKey] = []
                for step in 0...250 {
                    let now = Double(step) / 10
                    let event: TrackKey?? = switch step {
                    case 0: .some(Self.a)
                    case 100: .some(nil)
                    case 100 + gapSteps: .some(next)
                    default: .none
                    }
                    if let event {
                        let result = hold.receive(event, at: now)
                        published = result.published
                        holdUntil = result.holdUntil
                    } else if let until = holdUntil, now >= until {
                        published = hold.expire(at: until)
                        holdUntil = nil
                    }
                    if step > 0, published == nil { sawNil = true }
                    if case .showing(let key, _) = banner.update(inputs(published), now: now), shown.last != key {
                        shown.append(key)
                    }
                }
                let expected: [TrackKey] = next == Self.a ? [] : [Self.b]
                #expect(shown == expected, "gap \(gapSteps), next \(next.title)")
                #expect(sawNil == (gapSteps == 50), "gap \(gapSteps), next \(next.title)")
            }
        }
    }

    @Test func emptyTitleIsNotFirstBaseline() {
        var banner = TrackBanner()
        let empty = TrackKey(title: "", artist: "", source: "com.apple.Music")
        #expect(banner.update(inputs(empty), now: 0) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 0.5) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 5) == .hidden)
    }

    @Test func openPanelUpdatesInPlace() {
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b, panelOpen: true), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b, panelOpen: true), now: 11) == .hidden)
        var now = 12.0
        while now <= 18 {
            #expect(banner.update(inputs(Self.b), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
    }

    @Test func suppressedChangeBecomesBaseline() {
        // Остров скрыт полноэкранным приложением при «Скрывать в полноэкранном режиме».
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b, suppressed: true), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b, suppressed: true), now: 12) == .hidden)
        var now = 13.0
        while now <= 18 {
            #expect(banner.update(inputs(Self.b), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
    }

    @Test func disabledNeverShowsAndLeavesNoBacklog() {
        var banner = withBaseline()
        var now = 10.0
        for key in [Self.b, Self.c, Self.d] {
            for _ in 0..<20 {
                #expect(banner.update(inputs(key, enabled: false), now: now) == .hidden, "t \(now)")
                now += 0.25
            }
        }
        // Включили: текущий трек D уже базовый.
        while now <= 30 {
            #expect(banner.update(inputs(Self.d), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
        // Следующая смена снова показывается.
        _ = banner.update(inputs(Self.e), now: 31)
        #expect(isShowing(banner.update(inputs(Self.e), now: 31.31)))
    }

    @Test func cancelHidesAndKeepsBaseline() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        banner.cancel()
        #expect(banner.deadline == nil)
        var now = 10.5
        while now <= 18 {
            #expect(banner.update(inputs(Self.b), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
    }

    @Test func cancelCountsAsHideForGap() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        _ = banner.update(inputs(Self.b), now: 11)
        banner.cancel()
        _ = banner.update(inputs(Self.c), now: 11.2)
        #expect(banner.update(inputs(Self.c), now: 11.6) == .hidden)
        #expect(banner.update(inputs(Self.c), now: 11.99) == .hidden)
        #expect(isShowing(banner.update(inputs(Self.c), now: 12.01)))
    }

    @Test func sourceChangeCountsAsNewTrack() {
        var banner = withBaseline()
        let other = TrackKey(title: Self.a.title, artist: Self.a.artist, source: "com.spotify.client")
        _ = banner.update(inputs(other), now: 10)
        #expect(banner.update(inputs(other), now: 10.31) == .showing(other, textVisible: true))
    }

    @Test func blockingHidesAtOnce() {
        // Пауза скрывает не сразу: `pauseHidesVisibleBannerAfterDebounce`.
        let hiders: [TrackBannerInputs] = [
            inputs(Self.b, suppressed: true),
            inputs(Self.b, panelOpen: true),
            inputs(Self.b, enabled: false),
        ]
        for hider in hiders {
            var banner = withBaseline()
            _ = banner.update(inputs(Self.b), now: 10)
            #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
            #expect(banner.update(hider, now: 11) == .hidden, "\(hider)")
            #expect(banner.deadline == nil)
            // Причина ушла: тот же трек уже показан, баннер не возвращается.
            #expect(banner.update(inputs(Self.b), now: 11.5) == .hidden, "\(hider)")
            #expect(banner.update(inputs(Self.b), now: 13) == .hidden, "\(hider)")
        }
    }

    @Test func deadlineNamesNextEvent() throws {
        var banner = withBaseline()
        #expect(banner.deadline == nil)
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(try #require(banner.deadline) == 10 + TrackBanner.settleDelay)
        _ = banner.update(inputs(Self.b), now: 10.3)
        let shown = 10 + TrackBanner.settleDelay
        let end = shown + TrackBanner.openDuration + TrackBanner.visibleDuration
        #expect(try #require(banner.deadline) == end - TrackBanner.textLead)
        _ = banner.update(inputs(Self.b), now: end - TrackBanner.textLead)
        #expect(try #require(banner.deadline) == end)
        _ = banner.update(inputs(Self.b), now: end)
        #expect(banner.deadline == nil)
        // Новая смена сразу после скрытия ждет минимальный промежуток.
        _ = banner.update(inputs(Self.c), now: end + 0.1)
        #expect(try #require(banner.deadline) == end + TrackBanner.minimumGap)
    }

    @Test func blockedChangeWhilePausedBecomesBaseline() {
        // Панель открыта, остров подавлен или настройка выключена: смена на паузе тоже молча
        // становится базовой, и когда воспроизведение пойдет, баннера нет.
        let blockers: [(Bool, Bool, Bool)] = [(true, false, true), (false, true, true), (false, false, false)]
        for (panelOpen, suppressed, enabled) in blockers {
            var banner = withBaseline()
            let paused = inputs(Self.b, playing: false, enabled: enabled, panelOpen: panelOpen, suppressed: suppressed)
            #expect(banner.update(paused, now: 10) == .hidden)
            #expect(banner.update(paused, now: 11) == .hidden)
            #expect(banner.deadline == nil)
            var now = 12.0
            while now <= 18 {
                #expect(banner.update(inputs(Self.b), now: now) == .hidden, "\(paused) t \(now)")
                now += 0.25
            }
        }
    }

    @Test func titleOfWhitespaceAndNewlinesIsEmpty() {
        var banner = withBaseline()
        let blank = TrackKey(title: " \n\t\r\n ", artist: "Другой", source: "com.apple.Music")
        var now = 10.0
        while now < 15 {
            #expect(banner.update(inputs(blank), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
        // Пустое название не стало базовым: возврат к A без баннера.
        #expect(banner.update(inputs(Self.a), now: 16) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 18) == .hidden)
        // И не может стать первым базовым.
        var fresh = TrackBanner()
        #expect(fresh.update(inputs(blank), now: 0) == .hidden)
        #expect(fresh.update(inputs(Self.a), now: 0.5) == .hidden)
        #expect(fresh.update(inputs(Self.a), now: 5) == .hidden)
    }

    @Test func shortPauseKeepsVisibleBanner() {
        // Переключение трека иногда приходит с короткой паузой: баннер не мигает.
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(banner.update(inputs(Self.b, playing: false), now: 11) == .showing(Self.b, textVisible: true))
        #expect(banner.update(inputs(Self.b, playing: false), now: 11.29) == .showing(Self.b, textVisible: true))
        #expect(banner.update(inputs(Self.b), now: 11.29) == .showing(Self.b, textVisible: true))
        #expect(banner.update(inputs(Self.b), now: 12) == .showing(Self.b, textVisible: true))
        // Конец показа прежний.
        #expect(banner.update(inputs(Self.b), now: 13.79) == .showing(Self.b, textVisible: false))
        #expect(banner.update(inputs(Self.b), now: 13.81) == .hidden)
    }

    @Test func pauseHidesVisibleBannerAfterDebounce() throws {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(banner.update(inputs(Self.b, playing: false), now: 11) == .showing(Self.b, textVisible: true))
        #expect(try #require(banner.deadline) == 11 + TrackBanner.pauseDebounce)
        // Скрытие в 11.3, даже если следующий вызов позже.
        #expect(banner.update(inputs(Self.b, playing: false), now: 11.5) == .hidden)
        #expect(banner.deadline == nil)
        // Воспроизведение снова: тот же трек уже показан, а новый ждет промежутка от 11.3.
        #expect(banner.update(inputs(Self.b), now: 11.6) == .hidden)
        _ = banner.update(inputs(Self.c), now: 11.7)
        #expect(banner.update(inputs(Self.c), now: 12.29) == .hidden)
        #expect(banner.update(inputs(Self.c), now: 12.31) == .showing(Self.c, textVisible: true))
    }

    @Test func pauseDebounceStartsAtPause() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(isShowing(banner.update(inputs(Self.b, playing: false), now: 11)))
        #expect(isShowing(banner.update(inputs(Self.b, playing: false), now: 11.2)))
        #expect(banner.update(inputs(Self.b, playing: false), now: 11.31) == .hidden)
    }

    @Test func blockingDuringSettleDropsChangeForGood() {
        let blockers: [TrackBannerInputs] = [
            inputs(Self.b, panelOpen: true),
            inputs(Self.b, suppressed: true),
            inputs(Self.b, enabled: false),
        ]
        for blocker in blockers {
            var banner = withBaseline()
            _ = banner.update(inputs(Self.b), now: 10)
            #expect(banner.update(blocker, now: 10.1) == .hidden, "\(blocker)")
            #expect(banner.deadline == nil, "\(blocker)")
            // Причина ушла до конца выдержки: B уже базовый, баннера нет.
            var now = 10.2
            while now <= 16 {
                #expect(banner.update(inputs(Self.b), now: now) == .hidden, "\(blocker) t \(now)")
                now += 0.05
            }
        }
    }

    @Test func cancelDropsPendingChange() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        banner.cancel()
        #expect(banner.deadline == nil)
        // Прежняя выдержка не срабатывает: та же смена ждет заново с первого вызова после отмены.
        #expect(banner.update(inputs(Self.b), now: 10.31) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 10.6) == .hidden)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.62)))
        // Так модель и вызывает: отмена при раскрытии, следующий вызов с открытой панелью.
        var expanded = withBaseline()
        _ = expanded.update(inputs(Self.c), now: 20)
        _ = expanded.update(inputs(Self.c, panelOpen: true), now: 20.1)
        expanded.cancel()
        #expect(expanded.update(inputs(Self.c, panelOpen: true), now: 20.2) == .hidden)
        var now = 21.0
        while now <= 26 {
            #expect(expanded.update(inputs(Self.c), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
    }

    @Test func changeInLastMomentsHidesThenShowsAfterGap() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        // Показ кончается в 13.8; C в 13.7 выдержку кончает уже после него.
        #expect(banner.update(inputs(Self.c), now: 13.7) == .showing(Self.b, textVisible: false))
        #expect(banner.update(inputs(Self.c), now: 13.79) == .showing(Self.b, textVisible: false))
        #expect(banner.update(inputs(Self.c), now: 13.85) == .hidden)
        #expect(banner.update(inputs(Self.c), now: 14.79) == .hidden)
        #expect(banner.update(inputs(Self.c), now: 14.81) == .showing(Self.c, textVisible: true))
    }

    @Test func pendingChangeReplacedDuringGap() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(banner.update(inputs(Self.b), now: 13.81) == .hidden)
        _ = banner.update(inputs(Self.c), now: 14.0)
        // D сменил C, пока C ждал промежутка: выдержка D кончается в 14.9, после промежутка.
        #expect(banner.update(inputs(Self.d), now: 14.6) == .hidden)
        #expect(banner.update(inputs(Self.d), now: 14.81) == .hidden)
        #expect(banner.update(inputs(Self.d), now: 14.89) == .hidden)
        #expect(banner.update(inputs(Self.d), now: 14.91) == .showing(Self.d, textVisible: true))
        // Смена до конца промежутка показывается ровно в его конец.
        var early = withBaseline()
        _ = early.update(inputs(Self.b), now: 10)
        _ = early.update(inputs(Self.b), now: 10.31)
        _ = early.update(inputs(Self.c), now: 14.0)
        _ = early.update(inputs(Self.d), now: 14.2)
        #expect(early.update(inputs(Self.d), now: 14.79) == .hidden)
        #expect(early.update(inputs(Self.d), now: 14.81) == .showing(Self.d, textVisible: true))
    }

    @Test func constantsMatchSpec() {
        #expect(TrackBanner.settleDelay == 0.3)
        #expect(TrackBanner.minimumGap == 1.0)
        #expect(TrackBanner.openDuration == 0.5)
        #expect(TrackBanner.visibleDuration == 3.0)
        #expect(TrackBanner.textLead == 0.12)
        #expect(TrackBanner.pauseDebounce == 0.3)
    }
}
