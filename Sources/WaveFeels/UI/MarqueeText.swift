import SwiftUI

/// Строка в одну линию. Если текст помещается, это обычный `Text` без таймеров и анимаций.
/// Если нет, это бегущая строка по кругу: 2 с стоит в начале, затем уезжает влево со скоростью
/// 30 pt/с, а через 36 pt за ней идет вторая копия; когда копия встает на место начала, все
/// повторяется. Правый край затухает маской на 16 pt всегда, левый только пока текст движется.
///
/// Ширина всегда предложенная, а не ширина текста: длинная строка не раздвигает соседей.
/// Выбор между обычной и бегущей строкой делает `ViewThatFits` при раскладке, поэтому снимок
/// (`ImageRenderer`) сразу показывает начало длинного текста с затуханием справа. Прокрутка
/// живет в `task` и останавливается вместе с видом: бегущая строка есть только в раскрытой панели.
/// При «Уменьшении движения» текст не прокручивается: видно начало и затухание справа.
struct MarqueeText: View {
    /// Сколько текст стоит в начале перед каждым кругом.
    static let hold: Duration = .seconds(2)
    /// Скорость прокрутки, pt/с.
    static let speed: CGFloat = 30
    /// Промежуток между концом текста и его копией.
    static let gap: CGFloat = 36
    static let fadeWidth: CGFloat = 16
    /// Как быстро появляется и пропадает затухание левого края, с.
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
    /// Круг зависит от текста и его ширины; новый круг начинается с начала.
    private struct Trip: Equatable {
        var text: String
        /// Путь за круг: ширина текста и промежуток; 0, если прокрутки нет.
        var distance: CGFloat
    }

    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// Текст движется: левый край затухает.
    @State private var moving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let overflows = textWidth - boxWidth > 0.5
        let distance = overflows && !reduceMotion ? textWidth + MarqueeText.gap : 0
        // Место задает скрытая строка: высота одной строки, ширина ровно предложенная (минимум 0).
        // Сам текст во всю длину лежит поверх и в раскладке не участвует; маска обрезает его по месту.
        Text(verbatim: text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: MarqueeText.gap) {
                    label
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    // Копия, которая въезжает следом; до начала движения она за правым краем.
                    label
                        .accessibilityHidden(true)
                }
                .fixedSize()
                .offset(x: offset)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .mask { edgeMask }
            .task(id: Trip(text: text, distance: distance)) {
                await loop(distance: distance)
            }
    }

    private var label: some View {
        Text(verbatim: text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
    }

    private var edgeMask: some View {
        HStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                Rectangle().opacity(moving ? 0 : 1)
            }
            .frame(width: MarqueeText.fadeWidth)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: MarqueeText.fadeWidth)
        }
    }

    private func loop(distance: CGFloat) async {
        jumpToStart()
        moving = false
        guard distance > 0 else { return }
        let lap = Double(distance / MarqueeText.speed)
        let fade = Animation.easeInOut(duration: MarqueeText.fadeDuration)
        do {
            while true {
                try await Task.sleep(for: MarqueeText.hold)
                withAnimation(fade) { moving = true }
                withAnimation(.linear(duration: lap)) { offset = -distance }
                try await Task.sleep(for: .seconds(lap))
                // Копия стоит ровно там, где начинался текст: прыжок к началу незаметен.
                jumpToStart()
                withAnimation(fade) { moving = false }
            }
        } catch {
            // Вид исчез или текст сменился: следующий круг начнется с начала.
        }
    }

    private func jumpToStart() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = 0 }
    }
}
