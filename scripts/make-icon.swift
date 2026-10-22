// Рисует иконку WaveFeels: черная челка с камерой сверху и три волны под ней.
// Использование: swift scripts/make-icon.swift <out.iconset> [<sizes.png> [<AppIcon.icon>]]
// В <out.iconset> пишутся icon_16x16.png ... icon_512x512@2x.png для `iconutil -c icns`,
// <sizes.png> это лист со всеми размерами для проверки на глаз, <AppIcon.icon> это пакет
// Icon Composer для macOS 26 (три слоя во весь холст, его собирает `xcrun actool`).
// Каждый размер рисуется заново, а не уменьшается из 1024: на 16 и 32 px челка крупнее,
// линии толще, волн меньше периодов, нет свечения, камеры и вогнутых плеч.
// Только системные фреймворки macOS, без WaveCore. Цвета волн как в палитре по умолчанию.
//
// Вся геометрия задана в единицах холста 1024 с осью y вниз (контекст перевернут и
// масштабирован). Тени и размытие в CoreGraphics и CoreImage меряются в пикселях устройства,
// поэтому их размеры умножаются на масштаб `Canvas.k` явно.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct RGB {
    var r: Double
    var g: Double
    var b: Double

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(alpha))
    }

    /// Цвет в записи icon.json: `srgb:r,g,b,a`.
    var iconJSON: String {
        String(format: "srgb:%.5f,%.5f,%.5f,1.00000", r, g, b)
    }
}

/// Насколько подробно рисуется размер.
struct Detail {
    /// Периоды несущей на половину ширины, по слою (бас, середина, верх). Сколько элементов,
    /// столько волн рисуется.
    var carriers: [Double]
    /// Размах слоя, доля от расстояния между осью и челкой.
    var amplitudes: [Double]
    /// Толщина линий в единицах холста 1024.
    var widths: [CGFloat]
    var notchHalfWidth: CGFloat = 140
    var notchBottom: CGFloat = 226
    var notchRadius: CGFloat = 36
    /// Радиус вогнутых плеч челки у верхнего края, 0 без плеч.
    var notchShoulder: CGFloat = 14
    /// Объектив камеры в челке.
    var lens = true
    /// Тень под телом иконки и фиолетовое пятно света под челкой.
    var shadowAndPool = true
    /// Размытая копия волн и фиолетовая тень челки.
    var glow = true
    /// Верх градиента тела. На маленьких размерах светлее, чтобы челка читалась.
    var bodyTop = RGB(hex: 0x2C2550)

    static func forPixels(_ px: Int) -> Detail {
        let amplitudes = [1, 0.75, 0.55]
        switch px {
        case ...16:
            return Detail(
                carriers: [0.5, 0.7], amplitudes: [1, 0.6], widths: [96, 80],
                notchHalfWidth: 165, notchBottom: 250, notchRadius: 30, notchShoulder: 0,
                lens: false, shadowAndPool: false, glow: false, bodyTop: RGB(hex: 0x3A3166)
            )
        case ...32:
            return Detail(
                carriers: [0.5, 0.7, 0.9], amplitudes: [1, 0.74, 0.48], widths: [50, 42, 36],
                notchHalfWidth: 165, notchBottom: 250, notchShoulder: 0,
                lens: false, glow: false, bodyTop: RGB(hex: 0x3A3166)
            )
        case ...64:
            return Detail(carriers: [0.5, 0.85, 1.2], amplitudes: amplitudes, widths: [24, 20, 17], lens: false)
        case ...128:
            return Detail(carriers: [0.5, 0.85, 1.2], amplitudes: amplitudes, widths: [17, 14, 12])
        default:
            return Detail(carriers: [0.6, 1.1, 1.6], amplitudes: amplitudes, widths: [17, 14, 12])
        }
    }
}

/// Контекст отрисовки: `k` это пикселей устройства на единицу холста 1024.
struct Canvas {
    let ctx: CGContext
    let px: Int
    let k: CGFloat
    /// Тело иконки растянуто на весь холст (слои .icon, маску накладывает система).
    let fullBleed: Bool
}

enum Icon {
    static let violet = RGB(hex: 0x8B5CF6)
    static let cyan = RGB(hex: 0x22D3EE)
    static let pink = RGB(hex: 0xF472B6)
    /// Цвет слоя и цвет, к которому он уходит к краям (бас, середина, верх).
    static let layers: [(color: RGB, next: RGB)] = [(violet, cyan), (cyan, pink), (pink, violet)]

    // Сетка macOS: тело 824 из 1024 с отступом 100, радиус 22.37 % стороны, плавный угол.
    static let bodyOrigin: CGFloat = 100
    static let bodySide: CGFloat = 824
    static let cornerRatio: CGFloat = 0.2237
    static let cornerSmoothing: CGFloat = 0.6
    static let bodyMiddle = RGB(hex: 0x161230)
    static let bodyBottom = RGB(hex: 0x0C0A16)

    static let notchCenter: CGFloat = 512
    static let lensCenter = CGPoint(x: 512, y: 163)
    static let lensRadius: CGFloat = 11
    static let lensColor = RGB(hex: 0x15151E)
    static let lensGlintCenter = CGPoint(x: 508, y: 159)
    static let lensGlintRadius: CGFloat = 4
    static let lensGlintColor = RGB(hex: 0x4A5A90)

    /// Ось волн, зазор между гребнем баса и челкой, пределы по x.
    static let waveAxis: CGFloat = 580
    static let waveGap: CGFloat = 18
    static let waveLeft: CGFloat = 140
    static let waveRight: CGFloat = 884
    static let envelopePower = 1.1
    static let waveSegments = 200

    static let glowAlpha = 0.32
    static let glowWidthScale: CGFloat = 2.6
    static let glowBlur: CGFloat = 30

    static func srgb() -> CGColorSpace {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("no sRGB color space") }
        return space
    }

    static var bodyRect: CGRect {
        CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySide, height: bodySide)
    }

    static var bodyPath: CGPath {
        squircle(bodyRect, radius: cornerRatio * bodySide, smoothing: cornerSmoothing)
    }

    // MARK: - Пути

    static func radians(_ degrees: CGFloat) -> CGFloat {
        degrees * .pi / 180
    }

    /// Скругленный квадрат с плавными углами (сглаживание как в Figma): прямая сторона переходит
    /// в дугу через кривые Безье, кривизна растет без скачка.
    static func squircle(_ rect: CGRect, radius r: CGFloat, smoothing s: CGFloat) -> CGPath {
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        let p = min((1 + s) * r, min(w, h) / 2)
        let arcMeasure = 90 * (1 - s)
        let arcLength = CGFloat(sin(Double(radians(arcMeasure / 2)))) * r * CGFloat(2.0.squareRoot())
        let alpha = (90 - arcMeasure) / 2
        let p34 = r * CGFloat(tan(Double(radians(alpha / 2))))
        let beta = 45 * s
        let c = p34 * CGFloat(cos(Double(radians(beta))))
        let d = c * CGFloat(tan(Double(radians(beta))))
        let b = (p - arcLength - c - d) / 3
        let a = 2 * b
        func pt(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: px, y: py) }

        let path = CGMutablePath()
        path.move(to: pt(x + w - p, y))
        path.addCurve(to: pt(x + w - p + a + b + c, y + d), control1: pt(x + w - p + a, y), control2: pt(x + w - p + a + b, y))
        path.addArc(
            center: pt(x + w - r, y + r), radius: r,
            startAngle: radians(270 + alpha), endAngle: radians(360 - alpha), clockwise: false
        )
        path.addCurve(to: pt(x + w, y + p), control1: pt(x + w, y + p - a - b), control2: pt(x + w, y + p - a))
        path.addLine(to: pt(x + w, y + h - p))
        path.addCurve(
            to: pt(x + w - d, y + h - p + a + b + c),
            control1: pt(x + w, y + h - p + a), control2: pt(x + w, y + h - p + a + b)
        )
        path.addArc(
            center: pt(x + w - r, y + h - r), radius: r,
            startAngle: radians(alpha), endAngle: radians(90 - alpha), clockwise: false
        )
        path.addCurve(to: pt(x + w - p, y + h), control1: pt(x + w - p + a + b, y + h), control2: pt(x + w - p + a, y + h))
        path.addLine(to: pt(x + p, y + h))
        path.addCurve(
            to: pt(x + p - a - b - c, y + h - d),
            control1: pt(x + p - a, y + h), control2: pt(x + p - a - b, y + h)
        )
        path.addArc(
            center: pt(x + r, y + h - r), radius: r,
            startAngle: radians(90 + alpha), endAngle: radians(180 - alpha), clockwise: false
        )
        path.addCurve(to: pt(x, y + h - p), control1: pt(x, y + h - p + a + b), control2: pt(x, y + h - p + a))
        path.addLine(to: pt(x, y + p))
        path.addCurve(to: pt(x + d, y + p - a - b - c), control1: pt(x, y + p - a), control2: pt(x, y + p - a - b))
        path.addArc(
            center: pt(x + r, y + r), radius: r,
            startAngle: radians(180 + alpha), endAngle: radians(270 - alpha), clockwise: false
        )
        path.addCurve(to: pt(x + p, y), control1: pt(x + p - a - b, y), control2: pt(x + p - a, y))
        path.closeSubpath()
        return path
    }

    /// Челка: начинается выше тела (лишнее срежет обрезка по телу или маска системы), нижние
    /// углы скруглены, у верхнего края вогнутые плечи.
    static func notch(_ detail: Detail) -> CGPath {
        let top = bodyOrigin, bottom = detail.notchBottom
        let rB = detail.notchRadius, rS = detail.notchShoulder
        let l = notchCenter - detail.notchHalfWidth, r = notchCenter + detail.notchHalfWidth
        let path = CGMutablePath()
        path.move(to: CGPoint(x: l - rS, y: top - 160))
        path.addLine(to: CGPoint(x: l - rS, y: top))
        if rS > 0 {
            path.addArc(center: CGPoint(x: l - rS, y: top + rS), radius: rS, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        }
        path.addLine(to: CGPoint(x: l, y: bottom - rB))
        path.addArc(center: CGPoint(x: l + rB, y: bottom - rB), radius: rB, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: r - rB, y: bottom))
        path.addArc(center: CGPoint(x: r - rB, y: bottom - rB), radius: rB, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: r, y: top + rS))
        if rS > 0 {
            path.addArc(center: CGPoint(x: r + rS, y: top + rS), radius: rS, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        }
        path.addLine(to: CGPoint(x: r + rS, y: top - 160))
        path.closeSubpath()
        return path
    }

    /// Волна слоя: симметрична относительно середины, гребни всех слоев сходятся под челкой,
    /// к краям огибающая `cos(π/2·u)^p` гасит размах до нуля.
    static func wave(_ index: Int, detail: Detail) -> CGPath {
        let amplitude = waveAxis - detail.notchBottom - waveGap
        let path = CGMutablePath()
        for step in 0...waveSegments {
            let x = -1 + 2 * Double(step) / Double(waveSegments)
            let u = min(abs(x), 1)
            let envelope = pow(cos(Double.pi / 2 * u), envelopePower)
            let y = detail.amplitudes[index] * envelope * cos(2 * Double.pi * detail.carriers[index] * u)
            let point = CGPoint(
                x: notchCenter + CGFloat(x) * (waveRight - waveLeft) / 2,
                y: waveAxis - amplitude * CGFloat(y)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
            transform: nil
        )
    }

    // MARK: - Заливки

    static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        guard let gradient = CGGradient(colorsSpace: srgb(), colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })
        else { fail("cannot make gradient") }
        return gradient
    }

    /// Цвет вдоль волны: свой цвет в середине, к краям смесь со следующим и прозрачность.
    static func lineGradient(_ index: Int, alpha: Double) -> CGGradient {
        let layer = layers[index]
        let edge = layer.color.mixed(with: layer.next, 0.55)
        return gradient([
            (0, edge.cg(0)),
            (0.22, edge.cg(0.6 * alpha)),
            (0.5, layer.color.cg(alpha)),
            (0.78, edge.cg(0.6 * alpha)),
            (1, edge.cg(0)),
        ])
    }

    static func strokeWave(_ ctx: CGContext, _ index: Int, detail: Detail, width: CGFloat, alpha: Double) {
        ctx.saveGState()
        ctx.addPath(wave(index, detail: detail))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            lineGradient(index, alpha: alpha),
            start: CGPoint(x: waveLeft, y: 0), end: CGPoint(x: waveRight, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    // MARK: - Части иконки

    /// Холст `px`×`px` с осью y вниз и единицами 1024. `fullBleed`: тело 824 растянуто на весь холст.
    static func makeCanvas(_ px: Int, fullBleed: Bool = false) -> Canvas {
        guard let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("cannot make \(px) px context") }
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: 1, y: -1)
        var k = CGFloat(px) / 1024
        ctx.scaleBy(x: k, y: k)
        if fullBleed {
            let stretch = 1024 / bodySide
            ctx.scaleBy(x: stretch, y: stretch)
            ctx.translateBy(x: -bodyOrigin, y: -bodyOrigin)
            k *= stretch
        }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        return Canvas(ctx: ctx, px: px, k: k, fullBleed: fullBleed)
    }

    /// Рисует картинку в пикселях устройства, в обход перевернутой системы координат.
    static func drawInDeviceSpace(_ canvas: Canvas, _ image: CGImage) {
        let ctx = canvas.ctx
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: canvas.px, height: canvas.px))
        ctx.restoreGState()
    }

    /// Почти черный фон, светлее и фиолетовее у челки, и пятно света под ней. Градиенты
    /// продолжаются за тело, так что в слое .icon фон заполняет весь холст.
    static func drawBackground(_ canvas: Canvas, _ detail: Detail) {
        let ctx = canvas.ctx
        ctx.drawLinearGradient(
            gradient([(0, detail.bodyTop.cg()), (0.5, bodyMiddle.cg()), (1, bodyBottom.cg())]),
            start: CGPoint(x: 0, y: bodyRect.minY), end: CGPoint(x: 0, y: bodyRect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        if detail.shadowAndPool {
            let center = CGPoint(x: notchCenter, y: detail.notchBottom + 120)
            ctx.drawRadialGradient(
                gradient([(0, violet.cg(0.32)), (0.45, violet.cg(0.096)), (1, violet.cg(0))]),
                startCenter: center, startRadius: 0, endCenter: center, endRadius: 460,
                options: [.drawsAfterEndLocation]
            )
        }
    }

    /// Свечение: толстые полупрозрачные копии волн, размытые CoreImage.
    static func glowImage(_ canvas: Canvas, _ detail: Detail) -> CGImage {
        let layer = makeCanvas(canvas.px, fullBleed: canvas.fullBleed)
        layer.ctx.setBlendMode(.plusLighter)
        for index in detail.carriers.indices {
            strokeWave(layer.ctx, index, detail: detail, width: detail.widths[index] * glowWidthScale, alpha: glowAlpha)
        }
        guard let sharp = layer.ctx.makeImage() else { fail("cannot read glow layer") }
        let input = CIImage(cgImage: sharp)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { fail("no CIGaussianBlur") }
        blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(glowBlur * canvas.k, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage?.cropped(to: input.extent) else { fail("blur failed") }
        let context = CIContext(options: [
            .useSoftwareRenderer: true,
            .workingColorSpace: srgb(),
            .outputColorSpace: srgb(),
        ])
        guard let image = context.createCGImage(output, from: input.extent) else { fail("cannot render glow") }
        return image
    }

    /// Свечение складывается с фоном (`.plusLighter`), а сами линии кладутся обычным наложением,
    /// чтобы гребни сохраняли цвета палитры и не выцветали в пастель.
    static func drawWaves(_ canvas: Canvas, _ detail: Detail) {
        let ctx = canvas.ctx
        if detail.glow {
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            drawInDeviceSpace(canvas, glowImage(canvas, detail))
            ctx.restoreGState()
        }
        for index in detail.carriers.indices {
            strokeWave(ctx, index, detail: detail, width: detail.widths[index], alpha: 1)
        }
    }

    /// Челка с фиолетовым отсветом волн снизу и объективом камеры.
    static func drawNotch(_ canvas: Canvas, _ detail: Detail) {
        let ctx = canvas.ctx
        ctx.saveGState()
        if detail.glow {
            // Смещение тени задается в пространстве устройства, где y идет вверх.
            ctx.setShadow(offset: CGSize(width: 0, height: -4 * canvas.k), blur: 36 * canvas.k, color: violet.cg(0.45))
        }
        ctx.addPath(notch(detail))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        if detail.lens {
            ctx.addPath(circle(lensCenter, lensRadius))
            ctx.setFillColor(lensColor.cg())
            ctx.fillPath()
            ctx.addPath(circle(lensGlintCenter, lensGlintRadius))
            ctx.setFillColor(lensGlintColor.cg(0.6))
            ctx.fillPath()
        }
    }

    /// Светлая кромка по внутреннему краю поверх челки: верхний блик идет через челку без
    /// разрыва, и темная иконка не теряется на темном Dock.
    static func drawRim(_ canvas: Canvas) {
        let ctx = canvas.ctx
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.addPath(bodyPath)
        ctx.setLineWidth(2 * max(3, 1 / canvas.k))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([
                (0, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2)),
                (0.5, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)),
                (1, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)),
            ]),
            start: CGPoint(x: 0, y: bodyRect.minY), end: CGPoint(x: 0, y: bodyRect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    static func render(px: Int) -> CGImage {
        let detail = Detail.forPixels(px)
        let canvas = makeCanvas(px)
        let ctx = canvas.ctx

        if detail.shadowAndPool {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -max(0.5, 8 * canvas.k)), blur: max(1, 20 * canvas.k),
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
            )
            ctx.addPath(bodyPath)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        drawBackground(canvas, detail)
        drawWaves(canvas, detail)
        drawNotch(canvas, detail)
        ctx.restoreGState()
        drawRim(canvas)

        guard let image = ctx.makeImage() else { fail("cannot read \(px) px icon") }
        return image
    }

    // MARK: - Пакет Icon Composer

    /// Пакет .icon для macOS 26: три слоя 1024 во весь холст (фон, волны со свечением, челка
    /// с камерой) без кромки и тени, их система рисует сама. Группы в icon.json идут сверху вниз.
    /// Стекло выключено, чтобы цвета волн остались как в .icns.
    static func writeIconPackage(to url: URL) {
        let assets = url.appendingPathComponent("Assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(assets.path): \(error)")
        }
        let detail = Detail.forPixels(1024)
        let parts: [(name: String, draw: (Canvas, Detail) -> Void)] = [
            ("notch", drawNotch),
            ("waves", drawWaves),
            ("background", drawBackground),
        ]
        var groups: [[String: Any]] = []
        for part in parts {
            let canvas = makeCanvas(1024, fullBleed: true)
            part.draw(canvas, detail)
            guard let image = canvas.ctx.makeImage() else { fail("cannot read \(part.name) layer") }
            let file = "\(part.name).png"
            writePNG(image, to: assets.appendingPathComponent(file))
            groups.append([
                "name": part.name,
                "layers": [["name": part.name, "image-name": file, "glass": false]],
                "shadow": ["kind": "none", "opacity": 0],
                "translucency": ["enabled": false, "value": 0],
            ])
        }
        let manifest: [String: Any] = [
            "fill": ["solid": bodyBottom.iconJSON],
            "groups": groups,
            "supported-platforms": ["squares": "shared"],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url.appendingPathComponent("icon.json"))
        } catch {
            fail("cannot write icon.json: \(error)")
        }
    }

    // MARK: - Файлы

    static func writePNG(_ image: CGImage, to url: URL, scale: Int = 1) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            fail("cannot create \(url.path)")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    }

    /// Лист для проверки: все размеры 1:1 на темном и светлом фоне, 32 и 16 px еще и увеличены
    /// до 192 px без сглаживания.
    static func contactSheet(_ images: [Int: CGImage]) -> CGImage {
        let width = 1340, height = 1160
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("cannot make sheet context") }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // В перевернутом контексте картинка ставится через свой переворот, иначе она вверх ногами.
        func place(_ image: CGImage?, _ rect: CGRect, smooth: Bool = true) {
            guard let image else { return }
            ctx.saveGState()
            ctx.interpolationQuality = smooth ? .high : .none
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }

        let half = CGFloat(height) / 2
        for (row, shade) in [(0, 0x1E1E1E), (1, 0xECECEC)] as [(Int, UInt32)] {
            let y0 = CGFloat(row) * half
            ctx.setFillColor(RGB(hex: shade).cg())
            ctx.fill(CGRect(x: 0, y: y0, width: CGFloat(width), height: half))
            let top = y0 + 20
            place(images[512], CGRect(x: 20, y: top, width: 512, height: 512))
            var x: CGFloat = 552
            for size in [256, 128, 64, 32, 16] {
                let side = CGFloat(size)
                place(images[size], CGRect(x: x, y: top + 512 - side, width: side, height: side))
                x += side + 16
            }
            place(images[32], CGRect(x: x, y: top, width: 192, height: 192), smooth: false)
            place(images[16], CGRect(x: x, y: top + 210, width: 192, height: 192), smooth: false)
        }
        guard let image = ctx.makeImage() else { fail("cannot read sheet") }
        return image
    }

    static func run(_ arguments: [String]) {
        guard (2...4).contains(arguments.count), arguments[1].hasSuffix(".iconset"),
              arguments.count < 4 || arguments[3].hasSuffix(".icon")
        else {
            FileHandle.standardError.write(
                Data("usage: swift make-icon.swift <out.iconset> [<sizes.png> [<AppIcon.icon>]]\n".utf8)
            )
            exit(2)
        }
        let iconset = URL(fileURLWithPath: arguments[1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(iconset.path): \(error)")
        }

        var images: [Int: CGImage] = [:]
        for px in [16, 32, 64, 128, 256, 512, 1024] {
            images[px] = render(px: px)
        }
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let image = images[points * scale] else { fail("missing \(points * scale) px render") }
                let suffix = scale == 2 ? "@2x" : ""
                let name = "icon_\(points)x\(points)\(suffix).png"
                writePNG(image, to: iconset.appendingPathComponent(name), scale: scale)
                print("wrote \(name)")
            }
        }
        if arguments.count >= 3 {
            writePNG(contactSheet(images), to: URL(fileURLWithPath: arguments[2]))
            print("wrote \(arguments[2])")
        }
        if arguments.count == 4 {
            writeIconPackage(to: URL(fileURLWithPath: arguments[3], isDirectory: true))
            print("wrote \(arguments[3])")
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

Icon.run(CommandLine.arguments)
