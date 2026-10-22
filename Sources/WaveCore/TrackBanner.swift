import Foundation

/// Чем один трек отличается от другого для баннера: название, исполнитель и источник.
public struct TrackKey: Sendable, Equatable {
    public var title: String
    public var artist: String
    /// Bundle ID приложения-источника: тот же трек в другом плеере считается новым.
    public var source: String

    public init(title: String, artist: String, source: String) {
        self.title = title
        self.artist = artist
        self.source = source
    }
}

/// Входы правил баннера, снимаются при каждом обновлении. Между вызовами `update` считаются
/// неизменными.
public struct TrackBannerInputs: Sendable, Equatable {
    /// Настройка «Показывать новый трек».
    public var enabled: Bool
    /// Текущий трек источника, `nil` если данных нет.
    public var track: TrackKey?
    public var isPlaying: Bool
    /// Раскрытая панель уже на экране: содержимое обновляется в ней, баннер не нужен.
    public var panelOpen: Bool
    /// Остров не должен показываться: экран заблокирован, дисплеи или система спят,
    /// пауза пользователя, остров скрыт полноэкранным приложением при
    /// «Скрывать в полноэкранном режиме».
    public var suppressed: Bool

    public init(enabled: Bool, track: TrackKey?, isPlaying: Bool, panelOpen: Bool, suppressed: Bool) {
        self.enabled = enabled
        self.track = track
        self.isPlaying = isPlaying
        self.panelOpen = panelOpen
        self.suppressed = suppressed
    }
}

public enum TrackBannerPhase: Sendable, Equatable {
    case hidden
    /// Баннер с треком. `textVisible` становится false за `TrackBanner.textLead` до закрытия.
    case showing(TrackKey, textVisible: Bool)
}

/// Правила баннера нового трека. Чистая логика: время приходит снаружи (`now`, секунды
/// монотонных часов), следующий момент, когда нужно позвать `update`, в `deadline`.
///
/// Базовый трек: последний принятый во время воспроизведения. После `init` и `reset` первый
/// увиденный трек становится базовым без баннера. Другой трек при воспроизведении, с непустым
/// названием (пробелы и переводы строк не в счет), включенной настройке, закрытой панели и без
/// подавления ждет `settleDelay` (новая смена начинает ожидание заново), затем показывается,
/// но не раньше `minimumGap` после скрытия прошлого баннера. Показ длится
/// `openDuration + visibleDuration`, текст уходит за `textLead` до конца. Смена во время показа
/// обновляет содержимое после своей выдержки и начинает показ заново. Смена при открытой панели,
/// подавлении или выключенной настройке молча становится базовой, даже на паузе; смена на паузе
/// без этого базовый трек не трогает. Подавление, открытая панель или выключение настройки
/// скрывают баннер сразу, пауза только если длится `pauseDebounce`: при переключении трека
/// Now Playing иногда на миг присылает паузу, и баннер не должен мигать.
public struct TrackBanner: Sendable {
    /// Ожидание, пока название, исполнитель и обложка устоятся, с.
    public static let settleDelay = 0.3
    /// Наименьший промежуток между скрытием баннера и показом следующего, с.
    public static let minimumGap = 1.0
    /// Время раскрытия баннера, с.
    public static let openDuration = 0.5
    /// Сколько баннер виден после раскрытия, с.
    public static let visibleDuration = 3.0
    /// За сколько до закрытия уходит текст, с.
    public static let textLead = 0.12
    /// Сколько должна длиться пауза, чтобы скрыть видимый баннер, с.
    public static let pauseDebounce = 0.3

    private struct Pending: Sendable {
        var key: TrackKey
        var since: Double
    }

    private struct Shown: Sendable {
        var key: TrackKey
        var start: Double
        var end: Double { start + TrackBanner.openDuration + TrackBanner.visibleDuration }
        var textEnd: Double { end - TrackBanner.textLead }
    }

    /// Базовый трек еще не выбран: после `init` и `reset`.
    private var awaitingBaseline = true
    private var baseline: TrackKey?
    private var pending: Pending?
    private var shown: Shown?
    /// С какого момента видимый баннер стоит на паузе.
    private var pausedSince: Double?
    private var lastHide = -Double.infinity
    private var lastNow = -Double.infinity

    public init() {}

    /// Запуск или пробуждение: все забыто, первый трек снова станет базовым без баннера.
    public mutating func reset() {
        self = TrackBanner()
    }

    /// Скрыть баннер сейчас (остров раскрылся). Базовый трек остается, ожидающая смена
    /// отбрасывается. Для промежутка `minimumGap` момент скрытия: последний `now` в `update`.
    public mutating func cancel() {
        pending = nil
        if shown != nil {
            hide(at: lastNow)
        }
    }

    /// Следующий момент, когда фаза изменится сама при тех же входах: конец выдержки,
    /// уход текста, скрытие после паузы или конец показа. `nil`, если ничего не ждет.
    public var deadline: Double? {
        var next: Double?
        if let pending {
            next = showTime(for: pending)
        }
        if let shown {
            var event = lastNow < shown.textEnd ? shown.textEnd : shown.end
            if let pausedSince {
                event = min(event, pausedSince + Self.pauseDebounce)
            }
            next = min(next ?? event, event)
        }
        return next
    }

    public mutating func update(_ inputs: TrackBannerInputs, now: Double) -> TrackBannerPhase {
        // Прошлые входы действовали до `now`: сначала события по времени.
        advance(to: now)
        lastNow = max(lastNow, now)

        let track = inputs.track.flatMap {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        if awaitingBaseline {
            if let track {
                baseline = track
                awaitingBaseline = false
            }
            return phase(at: now)
        }

        let blocked = !inputs.enabled || inputs.panelOpen || inputs.suppressed
        if shown != nil, blocked {
            hide(at: now)
        }

        if let track, track != baseline, blocked {
            baseline = track
            pending = nil
        } else if let track, track != baseline, inputs.isPlaying {
            if pending?.key != track {
                pending = Pending(key: track, since: now)
            }
        } else {
            pending = nil
        }

        if shown != nil, !inputs.isPlaying {
            pausedSince = pausedSince ?? now
        } else {
            pausedSince = nil
        }

        advance(to: now)
        return phase(at: now)
    }

    private mutating func hide(at time: Double) {
        shown = nil
        pausedSince = nil
        lastHide = time
    }

    /// Когда ожидающая смена покажется: после выдержки, а если баннера нет, то и не раньше
    /// `minimumGap` после скрытия прошлого.
    private func showTime(for pending: Pending) -> Double {
        let settled = pending.since + Self.settleDelay
        return shown == nil ? max(settled, lastHide + Self.minimumGap) : settled
    }

    /// Применяет по порядку события до `now`: показ ожидающей смены и скрытие (конец показа
    /// или пауза дольше `pauseDebounce`).
    private mutating func advance(to now: Double) {
        while true {
            var end = shown?.end ?? .infinity
            if let pausedSince {
                end = min(end, pausedSince + Self.pauseDebounce)
            }
            if let next = pending {
                let start = showTime(for: next)
                if start <= now, start < end {
                    shown = Shown(key: next.key, start: start)
                    baseline = next.key
                    pending = nil
                    continue
                }
            }
            guard shown != nil, end <= now else { return }
            hide(at: end)
        }
    }

    private func phase(at now: Double) -> TrackBannerPhase {
        guard let shown else { return .hidden }
        return .showing(shown.key, textVisible: now < shown.textEnd)
    }
}
