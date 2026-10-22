import AppKit
import SwiftUI
import WaveCore

/// Что показывает баннер нового трека.
struct TrackBannerContent {
    var title: String
    /// Исполнитель; `nil`, если его нет.
    var artist: String?
    /// Обложка трека; без нее значок источника.
    var artwork: PanelArtwork?
    /// Значок приложения-источника; без него нейтральная плитка с нотой.
    var icon: NSImage?
    /// Текст виден: уходит за `TrackBanner.textLead` до закрытия.
    var textVisible: Bool
}

/// Содержимое баннера нового трека на видимом теле баннера (`IslandGeometry.bannerBody`,
/// 400×84 pt): слева обложка 56 pt со скруглением 10 pt (без нее значок источника), под
/// вырезом название 15 pt semibold и исполнитель 12 pt белым с прозрачностью 0.7, оба в одну
/// строку (`lineLimit(1)` обрезает с многоточием в конце). Кнопок и прогресса нет, волны
/// справа от выреза рисует сцена острова. Раскладка из `NotchLayout.bannerContent`.
///
/// `content == nil`: баннер закрыт, вид пуст. Обложка появляется и уходит прозрачностью вместе
/// с формой, текст появляется на 0.08 с позже и уходит за 0.12 с, когда `textVisible` гаснет.
/// Новый трек в открытом баннере сменяет текст и обложку плавно за 0.2 с. Вид всегда в дереве,
/// а меняется только его содержимое: так у текста срабатывает своя задержка появления.
struct TrackBannerView: View {
    static let artworkSize: CGFloat = 56
    static let artworkRadius: CGFloat = 10
    static let titleSize: CGFloat = 15
    static let artistSize: CGFloat = 12
    static let artistOpacity = 0.7
    static let artistSpacing: CGFloat = 2
    /// Смена трека в открытом баннере.
    static let crossfade = Animation.easeInOut(duration: 0.2)
    /// Текст появляется чуть позже формы и уходит до ее закрытия.
    static let textDelay = 0.08
    static var textTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(textDelay)),
            removal: .opacity.animation(.easeIn(duration: TrackBanner.textLead))
        )
    }

    let content: TrackBannerContent?
    let layout: BannerLayout

    var body: some View {
        let text = content?.textVisible == true ? content : nil
        ZStack(alignment: .topLeading) {
            if let content {
                BannerArtworkView(artwork: content.artwork, icon: content.icon)
                    .offset(x: layout.artwork.minX, y: layout.artwork.minY)
                    .transition(.opacity)
            }
            if let text {
                BannerTextView(title: text.title, artist: text.artist)
                    .frame(width: layout.text.width, height: layout.text.height, alignment: .leading)
                    .offset(x: layout.text.minX, y: layout.text.minY)
                    .transition(Self.textTransition)
            }
        }
    }
}

/// Название и исполнитель. Новый трек сменяет строки плавно.
private struct BannerTextView: View {
    let title: String
    let artist: String?

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: TrackBannerView.artistSpacing) {
                Text(verbatim: title)
                    .font(.system(size: TrackBannerView.titleSize, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                if let artist {
                    Text(verbatim: artist)
                        .font(.system(size: TrackBannerView.artistSize))
                        .foregroundStyle(Color.white.opacity(TrackBannerView.artistOpacity))
                        .lineLimit(1)
                }
            }
            .id(identity)
            .transition(.opacity)
        }
        .animation(TrackBannerView.crossfade, value: identity)
    }

    private var identity: String {
        title + "\n" + (artist ?? "")
    }
}

/// Обложка 56 pt с тонкой светлой обводкой; без обложки значок источника как есть (у значков
/// macOS своя маска, тело около 82 % стороны, поэтому рисуется крупнее), без него нейтральная
/// плитка с нотой. Смена плавная.
private struct BannerArtworkView: View {
    static let strokeOpacity = 0.1
    static let strokeWidth: CGFloat = 0.5
    static let fillOpacity = 0.1
    static let symbolSize: CGFloat = 22
    static let symbolOpacity = 0.45
    static let iconBodyFraction: CGFloat = 0.82

    let artwork: PanelArtwork?
    let icon: NSImage?

    var body: some View {
        let size = TrackBannerView.artworkSize
        let shape = RoundedRectangle(cornerRadius: TrackBannerView.artworkRadius, style: .continuous)
        ZStack {
            if let artwork {
                Image(decorative: artwork.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(Color.white.opacity(Self.strokeOpacity), lineWidth: Self.strokeWidth)
                    }
                    .id(artwork.id)
                    .transition(.opacity)
            } else if let icon {
                let drawn = (size / Self.iconBodyFraction).rounded()
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: drawn, height: drawn)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else {
                shape
                    .fill(Color.white.opacity(Self.fillOpacity))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: Self.symbolSize, weight: .medium))
                            .foregroundStyle(Color.white.opacity(Self.symbolOpacity))
                    }
                    .overlay {
                        shape.strokeBorder(Color.white.opacity(Self.strokeOpacity), lineWidth: Self.strokeWidth)
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(TrackBannerView.crossfade, value: artwork?.id)
        .animation(TrackBannerView.crossfade, value: icon == nil)
        .accessibilityHidden(true)
    }
}
