/// Чей темп помнит `BeatTracker` между сбросами (`reset(keepTempo:)`): трек Now Playing (с
/// удержанием `NowPlayingHold`, пустой снимок трек не меняет), под которым анализ последним подавал
/// трекеру шаги.
///
/// Анализ зовет `feeding` перед шагами трекера и `keepsTempo` на каждом сбросе (пауза, короткая
/// тишина, остановка подачи, пересборка tap). Темп сохраняется, только когда трек известен и тот же.
/// Трек сменился, пока трекер еще идет по памяти (следующий трек выбран на паузе, название пришло
/// позже звука): память чужая, трекер сбрасывается полностью. Смена трека посреди звука без памяти
/// трекер не сбрасывает: новый темп он находит сам, как в 1.1.
public struct TrackTempoMemory: Sendable {
    /// Трек последних шагов трекера; `nil`, пока шагов не было или трек неизвестен.
    public private(set) var track: TrackKey?

    public init() {}

    /// Сброс трекера при треке `current`: `true`, если темп можно сохранить.
    public func keepsTempo(current: TrackKey?) -> Bool {
        current != nil && current == track
    }

    /// Шаги трекера при треке `current`; `resuming` это `BeatTracker.resumingTempo`. `true`: трек
    /// сменился, пока трекер идет по памяти, его надо сбросить полностью до этих шагов.
    public mutating func feeding(current: TrackKey?, resuming: Bool) -> Bool {
        defer { track = current }
        return resuming && current != track
    }
}
