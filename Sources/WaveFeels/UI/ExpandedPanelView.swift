import SwiftUI
import WaveCore

/// Содержимое раскрытой панели над полосой волн: обложка, название и исполнитель, прогресс и
/// кнопки. Волны вдоль нижнего края (`WaveCanvas`, стиль `.panel`, 36 pt) рисует `IslandView`
/// вместе с остальной сценой острова, в том же кадре, что и форма.
///
/// Вид занимает `IslandGeometry.panelContent`: всю ширину панели от низа выреза (у капсулы от
/// верха панели) до верха полосы волн, и стоит в нем по центру по вертикали. Слева обложка
/// 72×72, справа от нее колонка текста, у правого края три кнопки. Колонка: название, исполнитель,
/// прогресс с прошедшим и оставшимся временем; она по центру обложки.
///
/// Трек берется из `AppModel.lastTrack`, он держится и на паузе. Кнопки и прогресс видны, только
/// если Now Playing работает и знает трек источника; иначе вместо названия трека показывается
/// название источника. Время обновляется раз в секунду (`TimelineView(.periodic)`), пока трек
/// играет и панель раскрыта; на паузе и в снимках время стоит.
struct ExpandedPanelView: View {
    static let artworkSize: CGFloat = 72
    static let artworkRadius: CGFloat = 14
    /// Сторона картинки обложки в пикселях: 72 pt на экране Retina.
    static let artworkPixels = 144
    /// Слева, как у волн, чтобы обложка и полоса волн начинались на одной линии.
    static let leadingInset: CGFloat = IslandGeometry.panelWaveSideInset
    /// Справа от рамки кнопок: значки встают примерно на линию волн.
    static let trailingInset: CGFloat = 16
    /// Справа без кнопок, как слева.
    static let trailingInsetWithoutControls: CGFloat = IslandGeometry.panelWaveSideInset
    static let artworkSpacing: CGFloat = 14
    static let controlsSpacing: CGFloat = 16
    static let titleSize: CGFloat = 15
    static let artistSize: CGFloat = 13
    static let artistOpacity = 0.65
    static let artistSpacing: CGFloat = 2
    static let progressSpacing: CGFloat = 12
    static let progressHeight: CGFloat = 3
    static let timeSize: CGFloat = 11
    static let timeOpacity = 0.5
    static let timeSpacing: CGFloat = 8
    static let buttonSize: CGFloat = 36
    static let buttonSpacing: CGFloat = 2
    static let symbolSize: CGFloat = 20
    /// Ширина трех кнопок с промежутками.
    static let controlsWidth: CGFloat = 3 * buttonSize + 2 * buttonSpacing

    /// Ширина колонки текста: все, что осталось в панели после отступов, обложки и кнопок.
    /// Задается явно, чтобы длинное название не раздвигало панель.
    static func textColumnWidth(controls: Bool) -> CGFloat {
        let panel = NotchGeometry.expandedSize.width
        let leading = leadingInset + artworkSize + artworkSpacing
        let trailing = controls ? controlsSpacing + controlsWidth + trailingInset : trailingInsetWithoutControls
        return max(panel - leading - trailing, 0)
    }

    /// Сколько ждать подтверждения паузы или игры от Now Playing, прежде чем вернуть значок.
    static let pendingPlaybackTimeout: Duration = .seconds(3)

    let model: AppModel
    /// Неподвижное время для снимков; `nil`: время идет.
    var date: Date? = nil

    /// Значок «пауза/играть» сразу после нажатия, до ответа Now Playing. Сбрасывается, когда
    /// состояние трека изменилось, когда панель закрылась и в любом случае через 3 с.
    @State private var pendingPlaying: Bool? = nil

    var body: some View {
        // Без Now Playing трека нет вовсе, даже если он остался с тех пор, когда адаптер работал.
        let playback = model.nowPlayingAvailable ? model.lastTrack : nil
        let source = model.effectiveSource.displayName
        let title = playback.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? source
        let artist = playback?.artist.flatMap { $0.isEmpty ? nil : $0 }

        HStack(spacing: 0) {
            PanelArtworkView(artwork: playback == nil ? nil : model.artwork, palette: model.palette)
                .padding(.trailing, Self.artworkSpacing)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: title, font: .system(size: Self.titleSize, weight: .semibold))
                    .foregroundStyle(Color.white)
                if let artist {
                    MarqueeText(text: artist, font: .system(size: Self.artistSize))
                        .foregroundStyle(Color.white.opacity(Self.artistOpacity))
                        .padding(.top, Self.artistSpacing)
                }
                if let playback, let duration = playback.duration, playback.elapsedTime != nil {
                    progress(playback, duration: duration)
                        .padding(.top, Self.progressSpacing)
                }
            }
            .frame(width: Self.textColumnWidth(controls: playback != nil), alignment: .leading)
            if let playback {
                controls(isPlaying: pendingPlaying ?? playback.isPlaying)
                    .fixedSize()
                    .padding(.leading, Self.controlsSpacing)
            }
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, playback == nil ? Self.trailingInsetWithoutControls : Self.trailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                model.adapter.send(.previousTrack)
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Предыдущий трек")

            Button {
                pendingPlaying = !isPlaying
                model.adapter.send(isPlaying ? .pause : .play)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: isPlaying)
            }
            .accessibilityLabel(isPlaying ? Text("Пауза") : Text("Играть"))

            Button {
                model.adapter.send(.nextTrack)
            } label: {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("Следующий трек")
        }
        .buttonStyle(IslandButtonStyle())
    }
}

// MARK: - Обложка

/// Обложка 72×72 со скруглением 14 pt (continuous) и тонкой светлой обводкой, чтобы темная
/// обложка не сливалась с черной панелью. Без обложки: градиент текущей палитры с `music.note`.
/// Новая обложка и новая палитра появляются плавно.
private struct PanelArtworkView: View {
    static let strokeOpacity = 0.1
    static let strokeWidth: CGFloat = 0.5
    static let placeholderShade = 0.18
    static let noteSize: CGFloat = 28
    static let noteOpacity = 0.92
    static let crossfade = Animation.easeInOut(duration: 0.35)

    let artwork: PanelArtwork?
    let palette: [PaletteColor]

    var body: some View {
        let size = ExpandedPanelView.artworkSize
        let shape = RoundedRectangle(cornerRadius: ExpandedPanelView.artworkRadius, style: .continuous)
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
                placeholder
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(Self.strokeOpacity), lineWidth: Self.strokeWidth)
        }
        .animation(Self.crossfade, value: artwork?.id)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        LinearGradient(
            colors: palette.map { Color(palette: $0) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(Color.black.opacity(Self.placeholderShade))
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: Self.noteSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(Self.noteOpacity))
        }
        .animation(.easeInOut(duration: PaletteFade.duration), value: palette)
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

/// Кнопка панели: значок 20 pt без рамки, при наведении под ним светлый круг 36 pt, при
/// нажатии круг ярче, а кнопка чуть сжимается. Без системных стилей: AppKit-кнопки здесь
/// смотрелись бы чужими, и `ImageRenderer` их не рисует.
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
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        let highlight = pressed ? Self.pressedOpacity : (hovering ? Self.hoverOpacity : 0)
        configuration.label
            .font(.system(size: ExpandedPanelView.symbolSize, weight: .medium))
            .foregroundStyle(Color.white.opacity(hovering || pressed ? 1 : Self.restingSymbolOpacity))
            .frame(width: ExpandedPanelView.buttonSize, height: ExpandedPanelView.buttonSize)
            .background {
                Circle().fill(Color.white.opacity(highlight))
            }
            .contentShape(Circle())
            .scaleEffect(pressed ? Self.pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: pressed)
    }
}
