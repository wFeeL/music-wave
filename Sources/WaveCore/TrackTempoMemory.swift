/// Чей темп помнит `BeatTracker` между сбросами (`reset(keepTempo:)`): трек Now Playing (с
/// удержанием `NowPlayingHold`, пустой снимок трек не меняет), под который трекер учился на шагах.
///
/// Анализ зовет `feeding` перед шагами трекера и `keepsTempo` на каждом сбросе (пауза, короткая
/// тишина, остановка подачи, пересборка tap). Темп сохраняется, только когда трек известен и тот же.
/// Известный трек сменился на другой известный (следующий трек посреди звука или на паузе): темп и
/// сетка прежнего трека новому не нужны, трекер сбрасывается полностью. Трек пропал или появился,
/// пока трекер идет по памяти темпа, тоже: память нельзя приписать звуку без трека. Без памяти
/// пропажа трека трекер не сбрасывает, а метка остается прежней: трекер учится на том же звуке, и
/// трек, который придет после пропажи, сравнивается с ней.
public struct TrackTempoMemory: Sendable {
    /// Трек, под который учился трекер; `nil`, пока шагов с известным треком не было и после сброса,
    /// когда трека нет.
    public private(set) var track: TrackKey?

    public init() {}

    /// Ключ трека для памяти темпа: только у источника-приложения. У всего звука системы Now Playing
    /// может описывать плеер на паузе, пока играет другой звук, и его трек темп не держит.
    public static func key(_ track: TrackKey?, source: AudioSource) -> TrackKey? {
        guard case .application = source else { return nil }
        return track
    }

    /// Сброс трекера при треке `current`: `true`, если темп можно сохранить.
    public func keepsTempo(current: TrackKey?) -> Bool {
        current != nil && current == track
    }

    /// Шаги трекера при треке `current`; `resuming` это `BeatTracker.resumingTempo`. `true`: трекер
    /// надо сбросить полностью до этих шагов (известный трек сменился на другой известный или трек
    /// сменился, пока трекер идет по памяти).
    public mutating func feeding(current: TrackKey?, resuming: Bool) -> Bool {
        let changed = current != track
        let drop = changed && (resuming || (current != nil && track != nil))
        if drop || current != nil {
            track = current
        }
        return drop
    }
}
