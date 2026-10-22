import AppKit
import SwiftUI
import WaveCore

/// Содержимое раскрытой панели над полосой волн: обложка, название и исполнитель, прогресс и
/// кнопки. Волны вдоль нижнего края (`WaveCanvas`, стиль `.panel`, 36 pt) рисует `IslandView`
/// вместе с остальной сценой острова, в том же кадре, что и форма.
///
/// Вид занимает `IslandGeometry.panelContent`: полосу высотой с обложку (72 pt) во всю ширину
/// рамки панели, ниже выреза на `NotchGeometry.notchClearance` (у капсулы на 16 pt от верха).
/// `inset`: от края рамки до линии содержимого, 16 pt от видимого края тела. Слева обложка,
/// за ней колонка текста, справа три кнопки; все на одной средней линии. Колонка: название,
/// исполнитель, прогресс с прошедшим и оставшимся временем.
///
/// Трек берется из `AppModel.panelTrack`: последний трек источника, он держится и на паузе.
/// Кнопки и прогресс видны, только если Now Playing работает и сейчас показывает именно
/// выбранный источник: команды уходят тому, кого он показывает. В остальных случаях слева
/// значок приложения-источника, его название и «Нет данных о треке», а справа кнопка
/// «Открыть», которая выводит источник вперед (у всего звука системы кнопки нет). Время
/// обновляется раз в секунду (`TimelineView(.periodic)`), пока трек играет и панель раскрыта;
/// на паузе и в снимках стоит.
struct ExpandedPanelView: View {
    static let artworkSize: CGFloat = IslandGeometry.panelContentHeight
    static let artworkRadius: CGFloat = 11
    /// Сторона картинки обложки в пикселях: 72 pt на экране Retina.
    static let artworkPixels = 144
    static let artworkSpacing: CGFloat = 14
    /// От колонки текста до рамки первой кнопки; до самого значка около 21 pt.
    static let controlsSpacing: CGFloat = 14
    static let titleSize: CGFloat = 15
    static let artistSize: CGFloat = 13
    static let artistOpacity = 0.65
    static let artistSpacing: CGFloat = 2
    static let progressSpacing: CGFloat = 12
    static let progressHeight: CGFloat = 3
    static let timeSize: CGFloat = 11
    static let timeOpacity = 0.55
    static let timeSpacing: CGFloat = 8
    static let buttonSize: CGFloat = 36
    static let buttonSpacing: CGFloat = 2
    /// «Пауза/играть» главная: крупнее и жирнее «назад» и «вперед».
    static let playSymbolSize: CGFloat = 22
    static let skipSymbolSize: CGFloat = 15
    /// Поле внутри рамки кнопки справа от значка `forward.fill` 15 pt (ширина около 22 pt):
    /// рамка заходит за линию содержимого на столько, и край значка встает ровно на нее.
    static let skipSymbolBearing: CGFloat = 7
    /// Ширина трех кнопок с промежутками (шаг центров 38 pt).
    static let controlsWidth: CGFloat = 3 * buttonSize + 2 * buttonSpacing
    static let missingTrackText = "Нет данных о треке"
    static let openSourceText = "Открыть"

    /// Ширина колонки текста рядом с кнопками: все, что осталось в рамке шириной `width`
    /// после отступов, обложки и кнопок. Задается явно, чтобы длинное название не раздвигало панель.
    static func textColumnWidth(width: CGFloat, inset: CGFloat) -> CGFloat {
        let leading = inset + artworkSize + artworkSpacing
        let trailing = controlsSpacing + controlsWidth + inset - skipSymbolBearing
        return max(width - leading - trailing, 0)
    }

    /// Сколько ждать подтверждения паузы или игры от Now Playing, прежде чем вернуть значок.
    static let pendingPlaybackTimeout: Duration = .seconds(3)

    let model: AppModel
    /// Ширина рамки панели.
    let width: CGFloat
    /// От края рамки до линии содержимого слева и справа.
    let inset: CGFloat
    /// Неподвижное время для снимков; `nil`: время идет.
    var date: Date? = nil

    /// Значок «пауза/играть» сразу после нажатия, до ответа Now Playing. Сбрасывается, когда
    /// состояние трека изменилось, когда панель закрылась и в любом случае через 3 с.
    @State private var pendingPlaying: Bool? = nil

    var body: some View {
        // Без Now Playing трека нет вовсе, даже если он остался с тех пор, когда адаптер работал;
        // если Now Playing показывает другое приложение, тоже: кнопки управляли бы им.
        let playback = model.panelTrack
        Group {
            if let playback {
                trackRow(playback)
            } else {
                sourceRow
            }
        }
        .frame(width: width, height: Self.artworkSize, alignment: .leading)
        .onChange(of: playback?.isPlaying) {
            // Now Playing подтвердил (или трек сменился): значок снова из состояния трека.
            pendingPlaying = nil
        }
        .onDisappear {
            pendingPlaying = nil
        }
        .task(id: pendingPlaying) {
            guard pendingPlaying != nil else { return }
            do {
                try await Task.sleep(for: Self.pendingPlaybackTimeout)
                pendingPlaying = nil
            } catch {
                // Нажали еще раз или панель закрылась.
            }
        }
    }

    // MARK: - Трек

    private func trackRow(_ track: NowPlayingInfo) -> some View {
        let title = track.title.isEmpty ? model.effectiveSource.displayName : track.title
        let artist = track.artist.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: 0) {
            PanelArtworkView(artwork: model.artwork)
                .padding(.trailing, Self.artworkSpacing)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: title, font: .system(size: Self.titleSize, weight: .semibold))
                    .foregroundStyle(Color.white)
                if let artist {
                    MarqueeText(text: artist, font: .system(size: Self.artistSize))
                        .foregroundStyle(Color.white.opacity(Self.artistOpacity))
                        .padding(.top, Self.artistSpacing)
                }
                if let duration = track.duration, track.elapsedTime != nil {
                    progress(track, duration: duration)
                        .padding(.top, Self.progressSpacing)
                }
            }
            .frame(width: Self.textColumnWidth(width: width, inset: inset), alignment: .leading)
            controls(isPlaying: pendingPlaying ?? track.isPlaying)
                .fixedSize()
                .padding(.leading, Self.controlsSpacing)
        }
        .padding(.leading, inset)
    }

    // MARK: - Источник без трека

    private var sourceRow: some View {
        let source = model.effectiveSource
        let opens: Bool = switch source {
        case .application: true
        case .systemWide: false
        }
        return HStack(spacing: 0) {
            SourceIconView(icon: model.sourceIcon())
                .padding(.trailing, Self.artworkSpacing)
            VStack(alignment: .leading, spacing: Self.artistSpacing) {
                MarqueeText(text: source.displayName, font: .system(size: Self.titleSize, weight: .semibold))
                    .foregroundStyle(Color.white)
                Text(verbatim: Self.missingTrackText)
                    .font(.system(size: Self.artistSize))
                    .foregroundStyle(Color.white.opacity(Self.artistOpacity))
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if opens {
                Button {
                    model.openSource()
                } label: {
                    Text(verbatim: Self.openSourceText)
                }
                .buttonStyle(PanelCapsuleButtonStyle())
                .fixedSize()
                .padding(.leading, Self.controlsSpacing)
            }
        }
        .padding(.horizontal, inset)
    }

    // MARK: - Прогресс

    @ViewBuilder
    private func progress(_ track: NowPlayingInfo, duration: Double) -> some View {
        if let date {
            PlaybackProgress(elapsed: track.elapsed(at: date) ?? 0, duration: duration)
        } else if track.isPlaying {
            TimelineView(.periodic(from: Self.secondBoundary(of: track), by: 1)) { context in
                PlaybackProgress(elapsed: track.elapsed(at: context.date) ?? 0, duration: duration)
            }
        } else {
            PlaybackProgress(elapsed: track.elapsed(at: Date()) ?? 0, duration: duration)
        }
    }

    /// Момент, когда позиция трека была целой секундой: от него тикает таймер, и цифры
    /// меняются вовремя, а не с опозданием до секунды.
    private static func secondBoundary(of track: NowPlayingInfo) -> Date {
        guard let timestamp = track.timestamp, let elapsed = track.elapsedTime, elapsed.isFinite else {
            return Date()
        }
        return timestamp.addingTimeInterval(-(elapsed - elapsed.rounded(.down)))
    }

    // MARK: - Кнопки

    private func controls(isPlaying: Bool) -> some View {
        HStack(spacing: Self.buttonSpacing) {
            Button {
                model.sendPanelCommand(.previousTrack)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: Self.skipSymbolSize, weight: .semibold))
            }
            .accessibilityLabel("Предыдущий трек")

            Button {
                pendingPlaying = !isPlaying
                model.sendPanelCommand(isPlaying ? .pause : .play)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: Self.playSymbolSize, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: isPlaying)
            }
            .accessibilityLabel(isPlaying ? Text("Пауза") : Text("Играть"))

            Button {
                model.sendPanelCommand(.nextTrack)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: Self.skipSymbolSize, weight: .semibold))
            }
            .accessibilityLabel("Следующий трек")
        }
        .buttonStyle(IslandButtonStyle())
    }
}

// MARK: - Обложка и значок источника

/// Плитки 72×72 со скруглением 11 pt (continuous) и тонкой светлой обводкой.
@MainActor
private enum PanelTile {
    static let strokeOpacity = 0.1
    static let strokeWidth: CGFloat = 0.5
    static let fillOpacity = 0.1
    static let symbolSize: CGFloat = 28
    static let symbolOpacity = 0.45

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ExpandedPanelView.artworkRadius, style: .continuous)
    }

    /// Нейтральная плитка с символом: вместо обложки или значка источника.
    static func neutral(symbol: String) -> some View {
        shape
            .fill(Color.white.opacity(fillOpacity))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(Color.white.opacity(symbolOpacity))
            }
    }
}

/// Обложка с обводкой, чтобы темная обложка не сливалась с черной панелью. Без обложки
/// нейтральная плитка с `music.note`; волны в этом случае в стандартной палитре. Новая обложка
/// появляется плавно.
private struct PanelArtworkView: View {
    static let crossfade = Animation.easeInOut(duration: 0.35)

    let artwork: PanelArtwork?

    var body: some View {
        let size = ExpandedPanelView.artworkSize
        ZStack {
            if let artwork {
                Image(decorative: artwork.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .id(artwork.id)
                    .transition(.opacity)
            } else {
                PanelTile.neutral(symbol: "music.note")
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(PanelTile.shape)
        .overlay {
            PanelTile.shape.strokeBorder(Color.white.opacity(PanelTile.strokeOpacity), lineWidth: PanelTile.strokeWidth)
        }
        .animation(Self.crossfade, value: artwork?.id)
        .accessibilityHidden(true)
    }
}

/// Значок приложения-источника как есть, без своей маски: у значков macOS она уже есть.
/// В шаблоне значка вокруг тела прозрачное поле (тело около 82 % стороны), поэтому значок
/// рисуется крупнее места обложки, по его центру и без обрезки: видимое тело совпадает с
/// 72 pt обложки. Без значка (весь звук системы) нейтральная плитка с динамиком.
private struct SourceIconView: View {
    /// Доля стороны значка macOS, которую занимает его видимое тело.
    static let iconBodyFraction: CGFloat = 0.82

    let icon: NSImage?

    var body: some View {
        let size = ExpandedPanelView.artworkSize
        Group {
            if let icon {
                let drawn = (size / Self.iconBodyFraction).rounded()
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: drawn, height: drawn)
                    .frame(width: size, height: size)
            } else {
                PanelTile.neutral(symbol: "speaker.wave.2.fill")
                    .overlay {
                        PanelTile.shape.strokeBorder(
                            Color.white.opacity(PanelTile.strokeOpacity), lineWidth: PanelTile.strokeWidth
                        )
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Прогресс

/// «1:03 ━━━━━━━━ −2:31»: полоска 3 pt между прошедшим и оставшимся временем. Цифры
/// моноширинные, чтобы полоска не дрожала каждую секунду.
private struct PlaybackProgress: View {
    static let trackOpacity = 0.2
    static let fillOpacity = 0.9

    let elapsed: Double
    let duration: Double

    var body: some View {
        let total = max(Int(duration.rounded(.down)), 0)
        let passed = min(max(Int(elapsed.rounded(.down)), 0), total)
        let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
        HStack(spacing: ExpandedPanelView.timeSpacing) {
            Text(verbatim: Self.format(passed))
            ZStack {
                Capsule().fill(Color.white.opacity(Self.trackOpacity))
                ProgressFill(fraction: fraction).fill(Color.white.opacity(Self.fillOpacity))
            }
            .frame(height: ExpandedPanelView.progressHeight)
            Text(verbatim: "\u{2212}" + Self.format(total - passed))
        }
        .font(.system(size: ExpandedPanelView.timeSize, weight: .medium).monospacedDigit())
        .foregroundStyle(Color.white.opacity(ExpandedPanelView.timeOpacity))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Прошло \(Self.format(passed)) из \(Self.format(total))")
    }

    /// «0:07», «3:41», «1:02:03».
    static func format(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let rest = seconds % 60
        let tail = String(format: "%02d", rest)
        return hours > 0 ? "\(hours):" + String(format: "%02d", minutes) + ":" + tail : "\(minutes):" + tail
    }
}

/// Заполненная часть полоски: капсула шириной `fraction` от полной, от левого края.
private struct ProgressFill: Shape {
    var fraction: Double

    nonisolated var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        let width = rect.width * CGFloat(min(max(fraction, 0), 1))
        guard width > 0 else { return Path() }
        let filled = CGRect(x: rect.minX, y: rect.minY, width: max(width, rect.height), height: rect.height)
        return Path(roundedRect: filled, cornerRadius: rect.height / 2)
    }
}

// MARK: - Кнопки

/// Кнопка-значок панели без рамки. Рамка 36×36; при наведении под значком светлый круг,
/// при нажатии круг ярче, а кнопка чуть сжимается. Размер значка задает сама кнопка. Без
/// системных стилей: AppKit-кнопки здесь смотрелись бы чужими, и `ImageRenderer` их не рисует.
private struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration)
    }
}

private struct IslandButtonBody: View {
    static let hoverOpacity = 0.1
    static let pressedOpacity = 0.18
    static let restingSymbolOpacity = 0.92
    static let pressedScale: CGFloat = 0.9

    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let highlight = pressed ? Self.pressedOpacity : (hovering ? Self.hoverOpacity : 0)
        configuration.label
            .foregroundStyle(Color.white.opacity(hovering || pressed ? 1 : Self.restingSymbolOpacity))
            .frame(width: ExpandedPanelView.buttonSize, height: ExpandedPanelView.buttonSize)
            .background {
                Circle().fill(Color.white.opacity(highlight))
            }
            .contentShape(Circle())
            .scaleEffect(pressed ? Self.pressedScale : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: pressed)
    }
}

/// Капсула с текстом («Открыть»): 13 pt medium, высота 28 pt, заливка белым 12 %, при наведении
/// и нажатии ярче.
private struct PanelCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelCapsuleButtonBody(configuration: configuration)
    }
}

private struct PanelCapsuleButtonBody: View {
    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 12
    static let textSize: CGFloat = 13
    static let restingOpacity = 0.12
    static let hoverOpacity = 0.18
    static let pressedOpacity = 0.24
    static let pressedScale: CGFloat = 0.96

    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let fill = pressed ? Self.pressedOpacity : (hovering ? Self.hoverOpacity : Self.restingOpacity)
        configuration.label
            .font(.system(size: Self.textSize, weight: .medium))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: Self.height)
            .background {
                Capsule().fill(Color.white.opacity(fill))
            }
            .contentShape(Capsule())
            .scaleEffect(pressed ? Self.pressedScale : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: pressed)
    }
}
