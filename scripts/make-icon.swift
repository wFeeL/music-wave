// Рисует иконку WaveFeels: черная челка сверху и три светящиеся волны под ней.
// Использование: swift scripts/make-icon.swift <out.iconset> [<sizes.png>]
// В <out.iconset> пишутся icon_16x16.png ... icon_512x512@2x.png для `iconutil -c icns`,
// необязательный второй аргумент это лист со всеми размерами для проверки на глаз.
// Каждый размер рисуется заново, а не уменьшается из 1024: на 16 и 32 px линии толще,
// волн меньше периодов, нет свечения, тени челки и вогнутых плеч.
// Только системные фреймворки macOS, без WaveCore. Цвета волн как в палитре по умолчанию.
//
// Вся геометрия задана в единицах холста 1024 с осью y вниз (контекст перевернут и
// масштабирован). Тени и размытие в CoreGraphics и CoreImage меряются в пикселях устройства,
// поэтому их размеры умножаются на масштаб `k` явно.
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
}

/// Насколько подробно рисуется размер.
struct Detail {
    /// Периоды несущей на половину ширины (бас, середина, верх).
    var carriers: [Double]
    /// Размах слоя, доля от расстояния между осью и челкой.
    var amplitudes: [Double]
    /// Толщина линий в единицах холста 1024.
    var widths: [CGFloat]
    /// Тень под телом иконки и фиолетовое пятно света под челкой.
    var shadowAndPool: Bool
    /// Размытая копия волн и фиолетовая тень челки.
    var glow: Bool
    /// Вогнутые плечи челки у верхнего края.
    var shoulders: Bool
    var notchRadius: CGFloat
    var lineAlpha: Double

    static func forPixels(_ px: Int) -> Detail {
        let simple = [0.5, 0.7, 0.9]
        let full = [0.6, 1.1, 1.6]
        switch px {
        case ...16:
            return Detail(
                carriers: simple, amplitudes: [1, 0.7, 0.42], widths: [80, 64, 56],
                shadowAndPool: false, glow: false, shoulders: false, notchRadius: 30, lineAlpha: 1
            )
        case ...32:
            return Detail(
                carriers: simple, amplitudes: [1, 0.74, 0.48], widths: [50, 42, 36],
                shadowAndPool: true, glow: false, shoulders: false, notchRadius: 50, lineAlpha: 0.95
            )
        case ...64:
            return Detail(
                carriers: full, amplitudes: [1, 0.75, 0.55], widths: [24, 20, 17],
                shadowAndPool: true, glow: true, shoulders: true, notchRadius: 50, lineAlpha: 0.95
            )
        default:
            return Detail(
                carriers: full, amplitudes: [1, 0.75, 0.55], widths: [17, 14, 12],
                shadowAndPool: true, glow: true, shoulders: true, notchRadius: 50, lineAlpha: 0.95
            )
        }
    }
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

    static let notchCenter: CGFloat = 512
    static let notchBottom: CGFloat = 270
    static let notchHalfWidth: CGFloat = 180
    static let notchShoulder: CGFloat = 24

    /// Ось волн, зазор между гребнем баса и челкой, пределы по x.
    static let waveAxis: CGFloat = 590
    static let waveGap: CGFloat = 18
    static let waveLeft: CGFloat = 140
    static let waveRight: CGFloat = 884
    static let envelopePower = 1.1
    static let waveSegments = 200

    static let glowAlpha = 0.5
    static let glowWidthScale: CGFloat = 3.2
    static let glowBlur: CGFloat = 22

    static func srgb() -> CGColorSpace {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("no sRGB color space") }
        return space
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

    /// Челка: начинается выше тела (лишнее срежет обрезка по телу), нижние углы скруглены,
    /// у верхнего края вогнутые плечи радиуса `shoulder`.
    static func notch(top: CGFloat, radius rB: CGFloat, shoulder rS: CGFloat) -> CGPath {
        let l = notchCenter - notchHalfWidth, r = notchCenter + notchHalfWidth, bottom = notchBottom
        let path = CGMutablePath()
        path.move(to: CGPoint(x: l - rS, y: top - 60))
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
        path.addLine(to: CGPoint(x: r + rS, y: top - 60))
        path.closeSubpath()
        return path
    }

    /// Волна слоя: симметрична относительно середины, гребни всех слоев сходятся под челкой,
    /// к краям огибающая `cos(π/2·u)^p` гасит размах до нуля.
    static func wave(_ index: Int, detail: Detail) -> CGPath {
        let amplitude = waveAxis - notchBottom - waveGap
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
            (0.14, edge.cg(0.85 * alpha)),
            (0.5, layer.color.cg(alpha)),
            (0.86, edge.cg(0.85 * alpha)),
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

    // MARK: - Отрисовка

    /// Контекст `px`×`px` с осью y вниз и единицами холста 1024.
    static func makeContext(_ px: Int) -> CGContext {
        guard let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("cannot make \(px) px context") }
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: 1, y: -1)
        let k = CGFloat(px) / 1024
        ctx.scaleBy(x: k, y: k)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Рисует картинку в пикселях устройства, в обход перевернутой системы координат.
    static func drawInDeviceSpace(_ ctx: CGContext, _ image: CGImage, px: Int) {
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        ctx.restoreGState()
    }

    /// Свечение: толстые полупрозрачные копии волн, размытые CoreImage.
    static func glowImage(px: Int, detail: Detail) -> CGImage {
        let k = CGFloat(px) / 1024
        let ctx = makeContext(px)
        ctx.setBlendMode(.plusLighter)
        for index in layers.indices {
            strokeWave(ctx, index, detail: detail, width: detail.widths[index] * glowWidthScale, alpha: glowAlpha)
        }
        guard let sharp = ctx.makeImage() else { fail("cannot read glow layer") }
        let input = CIImage(cgImage: sharp)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { fail("no CIGaussianBlur") }
        blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(glowBlur * k, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage?.cropped(to: input.extent) else { fail("blur failed") }
        let context = CIContext(options: [
            .useSoftwareRenderer: true,
            .workingColorSpace: srgb(),
            .outputColorSpace: srgb(),
        ])
        guard let image = context.createCGImage(output, from: input.extent) else { fail("cannot render glow") }
        return image
    }

    static func render(px: Int) -> CGImage {
        let detail = Detail.forPixels(px)
        let k = CGFloat(px) / 1024
        let ctx = makeContext(px)
        let bodyRect = CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySide, height: bodySide)
        let body = squircle(bodyRect, radius: cornerRatio * bodySide, smoothing: cornerSmoothing)
        let bodyTop = CGPoint(x: 0, y: bodyRect.minY)
        let bodyBottom = CGPoint(x: 0, y: bodyRect.maxY)

        // Тень тела. Смещение тени задается в пространстве устройства, где y идет вверх.
        if detail.shadowAndPool {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -max(0.5, 8 * k)), blur: max(1, 20 * k),
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
            )
            ctx.addPath(body)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()

        // Почти черный фон, чуть светлее и фиолетовее у челки.
        ctx.drawLinearGradient(
            gradient([
                (0, RGB(hex: 0x25203D).cg()),
                (0.5, RGB(hex: 0x120F1F).cg()),
                (1, RGB(hex: 0x08070D).cg()),
            ]),
            start: bodyTop, end: bodyBottom, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        if detail.shadowAndPool {
            let center = CGPoint(x: notchCenter, y: notchBottom + 120)
            ctx.drawRadialGradient(
                gradient([(0, violet.cg(0.32)), (0.45, violet.cg(0.096)), (1, violet.cg(0))]),
                startCenter: center, startRadius: 0, endCenter: center, endRadius: 460,
                options: [.drawsAfterEndLocation]
            )
        }

        ctx.setBlendMode(.plusLighter)
        if detail.glow {
            drawInDeviceSpace(ctx, glowImage(px: px, detail: detail), px: px)
        }
        for index in layers.indices {
            strokeWave(ctx, index, detail: detail, width: detail.widths[index], alpha: detail.lineAlpha)
        }
        ctx.setBlendMode(.normal)

        // Светлая кромка по внутреннему краю: темная иконка не теряется на темном Dock.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.setLineWidth(2 * max(3, 1 / k))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([
                (0, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2)),
                (0.5, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)),
                (1, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)),
            ]),
            start: bodyTop, end: bodyBottom, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()

        // Челка поверх кромки, с фиолетовым отсветом волн снизу.
        ctx.saveGState()
        if detail.glow {
            ctx.setShadow(offset: CGSize(width: 0, height: -4 * k), blur: 36 * k, color: violet.cg(0.45))
        }
        ctx.addPath(notch(top: bodyRect.minY, radius: detail.notchRadius, shoulder: detail.shoulders ? notchShoulder : 0))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.restoreGState()
        guard let image = ctx.makeImage() else { fail("cannot read \(px) px icon") }
        return image
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
        guard arguments.count == 2 || arguments.count == 3, arguments[1].hasSuffix(".iconset") else {
            FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.iconset> [<sizes.png>]\n".utf8))
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
        if arguments.count == 3 {
            writePNG(contactSheet(images), to: URL(fileURLWithPath: arguments[2]))
            print("wrote \(arguments[2])")
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

Icon.run(CommandLine.arguments)
