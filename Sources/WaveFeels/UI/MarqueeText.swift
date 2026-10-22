import SwiftUI

/// Строка в одну линию. Если текст помещается, это обычный `Text` без таймеров и анимаций.
/// Если нет: пауза 1.5 с, прокрутка влево со скоростью 30 pt/с до конца текста, пауза 1.5 с,
/// возврат к началу втрое быстрее, и снова. Обрезанные края затухают маской на 14 pt: правый,
/// пока конец текста скрыт, левый, пока скрыто начало.
///
/// Ширина всегда предложенная, а не ширина текста: длинная строка не раздвигает соседей.
/// Выбор между обычной и бегущей строкой делает `ViewThatFits` при раскладке, поэтому снимок
/// (`ImageRenderer`) сразу показывает начало длинного текста с затуханием справа. Прокрутка
/// живет в `task` и останавливается вместе с видом: бегущая строка есть только в раскрытой панели.
/// При «Уменьшении движения» текст не прокручивается: видно начало и затухание справа.
struct MarqueeText: View {
    static let pause: Duration = .milliseconds(1500)
    /// Скорость прокрутки, pt/с.
    static let speed: CGFloat = 30
    /// Возврат к началу во столько раз быстрее.
    static let returnSpeedup: CGFloat = 3
    static let fadeWidth: CGFloat = 14
    /// Как быстро появляется и пропадает затухание края, с.
    static let fadeDuration = 0.2

    let text: String
    let font: Font

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(verbatim: text)
                .font(font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            MarqueeScroller(text: text, font: font)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// Бегущая строка для текста шире своего места.
private struct MarqueeScroller: View {
    /// Поездка зависит от текста и того, насколько он длиннее места; новая поездка начинается с начала.
    private struct Trip: Equatable {
        var text: String
        var distance: CGFloat
        var reduceMotion: Bool
    }

    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// Начало текста ушло влево: левый край затухает.
    @State private var headHidden = false
    /// Конец текста дошел до правого края: правый край не затухает.
    @State private var tailShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let distance = max(textWidth - boxWidth, 0)
        // Место задает скрытая строка: высота одной строки, ширина ровно предложенная (минимум 0).
        // Сам текст во всю длину лежит поверх и в раскладке не участвует; маска обрезает его по месту.
        Text(verbatim: text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(verbatim: text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: offset)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .mask { edgeMask }
            .task(id: Trip(text: text, distance: distance, reduceMotion: reduceMotion)) {
                await scroll(distance: reduceMotion ? 0 : distance)
            }
    }

    private var edgeMask: some View {
        HStack(spacing: 0) {
            edge(fading: headHidden, from: .leading)
            Rectangle()
            edge(fading: !tailShown, from: .trailing)
        }
    }

    /// Край маски: плавный переход от прозрачного у самого края или сплошной, если затухания нет.
    private func edge(fading: Bool, from side: UnitPoint) -> some View {
        let inside: UnitPoint = side == .leading ? .trailing : .leading
        return ZStack {
            LinearGradient(colors: [.clear, .black], startPoint: side, endPoint: inside)
            Rectangle().opacity(fading ? 0 : 1)
        }
        .frame(width: MarqueeText.fadeWidth)
    }

    private func scroll(distance: CGFloat) async {
        offset = 0
        headHidden = false
        tailShown = false
        guard distance > 0.5 else { return }
        let forward = Double(distance / MarqueeText.speed)
        let back = forward / Double(MarqueeText.returnSpeedup)
        let fade = Animation.easeInOut(duration: MarqueeText.fadeDuration)
        do {
            while true {
                try await Task.sleep(for: MarqueeText.pause)
                withAnimation(.linear(duration: forward)) { offset = -distance }
                withAnimation(fade) { headHidden = true }
                try await Task.sleep(for: .seconds(forward))
                withAnimation(fade) { tailShown = true }
                try await Task.sleep(for: MarqueeText.pause)
                withAnimation(.easeInOut(duration: back)) { offset = 0 }
                withAnimation(fade) { tailShown = false }
                try await Task.sleep(for: .seconds(back))
                withAnimation(fade) { headHidden = false }
            }
        } catch {
            // Вид исчез или текст сменился: следующая поездка начнется с начала.
        }
    }
}
