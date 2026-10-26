/// Автовыбор источника: пока выбранное пользователем приложение молчит, а играет другое,
/// визуализация переходит на него и возвращается, когда снова играет выбранное.
///
/// Переход на другое приложение после `confirm` секунд непрерывной игры: короткий звук
/// уведомления источник не меняет. Возврат к выбранному, когда автоматическое молчит
/// `release` секунд, а выбранное играет. Пока автоматическое играет, источник не меняется,
/// даже если играет и выбранное или третье приложение: так два играющих приложения не
/// перекидывают источник друг другу. Помощники выбранного (`ProcessMatcher.bundleIDBelongs`)
/// считаются им самим. Из цепочки A, B, C возврат идет к A, выбору пользователя.
public struct AutoSourceSwitcher: Sendable {
    /// Секунды непрерывной игры другого приложения до перехода на него.
    public static let confirm = 1.0
    /// Секунды тишины автоматического приложения до возврата к играющему выбранному.
    public static let release = 2.0

    /// bundle ID приложения, выбранного автоматически; `nil`: источник выбран пользователем.
    public private(set) var override: String?

    /// Выбор пользователя на прошлом обновлении: его смена сбрасывает переход.
    private var lastChosen: String?
    /// Приложение, которое сейчас набирает `confirm`, и с какого момента.
    private var pending: (bundleID: String, since: Double)?
    /// С какого момента молчит автоматическое приложение.
    private var overrideSilentSince: Double?

    public init() {}

    /// Забывает автоматический выбор и все отсчеты.
    public mutating func reset() {
        override = nil
        lastChosen = nil
        pending = nil
        overrideSilentSince = nil
    }

    /// Возвращает bundle ID автоматического источника или `nil`, если звучит выбор пользователя.
    ///
    /// - Parameters:
    ///   - chosen: bundle ID источника пользователя; `nil` у всего звука системы, тогда
    ///     автовыбор не работает.
    ///   - playing: приложение, которое по Now Playing играет и выводит звук.
    ///   - chosenPlaying: выбранное играет (см. `appPlaying`).
    ///   - overridePlaying: автоматическое играет; без автоматического не важно.
    ///   - now: секунды, растут монотонно.
    public mutating func update(
        chosen: String?,
        playing: String?,
        chosenPlaying: Bool,
        overridePlaying: Bool,
        now: Double
    ) -> String? {
        if chosen != lastChosen {
            reset()
            lastChosen = chosen
        }
        guard let chosen, !chosen.isEmpty else {
            override = nil
            pending = nil
            overrideSilentSince = nil
            return nil
        }

        if override != nil {
            overrideSilentSince = overridePlaying ? nil : (overrideSilentSince ?? now)
            if chosenPlaying, let since = overrideSilentSince, elapsed(now, since, Self.release) {
                override = nil
                pending = nil
                overrideSilentSince = nil
                return nil
            }
        }

        // Кандидат: играет не выбранное, не его помощник и не текущее автоматическое. От
        // автоматического, пока оно играет, не уходим.
        let other = playing.flatMap { id -> String? in
            if id.isEmpty || ProcessMatcher.bundleIDBelongs(id, to: chosen) { return nil }
            if let override, ProcessMatcher.bundleIDBelongs(id, to: override) { return nil }
            return id
        }
        guard let other, override == nil || !overridePlaying else {
            pending = nil
            return override
        }
        let since: Double
        if let pending, pending.bundleID == other {
            since = pending.since
        } else {
            since = now
        }
        pending = (other, since)
        if elapsed(now, since, Self.confirm) {
            override = other
            pending = nil
            overrideSilentSince = nil
        }
        return override
    }

    /// Играет ли приложение `bundleID`. Если Now Playing показывает его (или его помощника),
    /// ответ дает `isPlaying` записи; иначе (Now Playing показывает другое приложение или
    /// недоступен) вывод звука его процессами. `outputRunning` вычисляется, только когда
    /// Now Playing ответа не дает.
    public static func appPlaying(
        _ bundleID: String,
        nowPlaying: NowPlayingInfo?,
        outputRunning: @autoclosure () -> Bool
    ) -> Bool {
        if let nowPlaying, nowPlaying.appBundleIDs.contains(where: { ProcessMatcher.bundleIDBelongs($0, to: bundleID) }) {
            return nowPlaying.isPlaying
        }
        return outputRunning()
    }

    /// Кандидат в автоматический источник по Now Playing: bundle ID приложения играющей записи
    /// (родитель, если есть: вкладка браузера дает браузер), если запись не относится к
    /// выбранному `chosen`. Вывод звука кандидатом проверяет приложение.
    public static func candidate(nowPlaying: NowPlayingInfo?, chosen: String) -> String? {
        guard let nowPlaying, nowPlaying.isPlaying else { return nil }
        let ids = nowPlaying.appBundleIDs
        guard let first = ids.first else { return nil }
        if ids.contains(where: { ProcessMatcher.bundleIDBelongs($0, to: chosen) }) { return nil }
        return first
    }

    private func elapsed(_ now: Double, _ since: Double, _ delay: Double) -> Bool {
        now - since >= delay - 1e-9
    }
}
