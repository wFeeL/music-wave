import Foundation

/// Удержание записи Now Playing через пустые снимки. При смене трека Яндекс Музыка на миг
/// присылает пустой снимок (или снимок без названия), и без удержания панель успевала показать
/// «Нет данных о треке», а потом уже новый трек.
///
/// Пустой снимок после трека: трек остается опубликованным до `holdUntil` (момент снимка плюс
/// `grace`). Повторные пустые снимки срок не продлевают. Настоящее значение до срока сменяет
/// трек сразу, тот же трек опубликованного значения не меняет. Если к сроку ничего не пришло,
/// владелец таймера зовет `expire(at:)`, и публикуется `nil`: трек правда кончился. Чистая
/// логика, время приходит снаружи (секунды).
public struct NowPlayingHold<Value: Equatable & Sendable>: Sendable {
    /// Сколько держать прежнее значение после пустого снимка, с.
    public static var grace: Double { 1.5 }

    private var published: Value?
    private var holdUntil: Double?

    public init() {}

    /// Снимок потока: `value` или `nil` (играть нечему). Возвращает, что публиковать, и срок
    /// удержания: не `nil`, пока держится прежнее значение, к этому моменту нужен `expire(at:)`.
    public mutating func receive(_ value: Value?, at time: Double) -> (published: Value?, holdUntil: Double?) {
        if let value {
            published = value
            holdUntil = nil
            return (value, nil)
        }
        guard published != nil else { return (nil, nil) }
        let until = holdUntil ?? time + Self.grace
        holdUntil = until
        return (published, until)
    }

    /// Таймер удержания сработал в момент `time`. Срок вышел: удержание снимается, возвращается
    /// `nil`. Иначе (удержания нет или срок еще не наступил) возвращается текущее значение.
    public mutating func expire(at time: Double) -> Value? {
        if let until = holdUntil, time >= until {
            published = nil
            holdUntil = nil
        }
        return published
    }
}
