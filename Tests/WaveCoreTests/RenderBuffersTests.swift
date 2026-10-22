import Foundation
import Testing
@testable import WaveCore

/// Точки волны и градиента в готовые буферы: результат бит в бит как у прежних функций.
/// Прежние `WaveShape.samples` и `WavePaint.stops` (до 1.1) повторены здесь как образец.
struct RenderBuffersTests {
    static let phases: [WavePhase] = (0..<9).map { WavePhase(carrier: Double($0) * 0.7, harmonic: Double($0) * 1.19) }
        + [WavePhase(carrier: .nan, harmonic: .infinity)]
    static let amplitudes: [Float] = [0, 0.05, 0.4, 0.8, 1, 1.7, -0.3, .nan]
    static let gains: [Double] = [0.5, 1, 1.6, 2, -1, .nan]
    static let counts = [1, 2, 3, 32, 64, 112, 224]

    @Test func samplesIntoBufferMatchLegacyBitForBit() {
        for profile in WaveProfile.allCases {
            for layer in WaveLayer.allCases {
                for count in Self.counts {
                    let envelope = WaveShape.Envelope(layer: layer, count: count, profile: profile)
                    #expect(envelope.count == count)
                    #expect(envelope.layer == layer && envelope.profile == profile)
                    var buffer = [Float](repeating: .nan, count: count)
                    for phase in Self.phases {
                        for amplitude in Self.amplitudes {
                            for gain in Self.gains {
                                let legacy = Self.legacySamples(
                                    layer: layer, amplitude: amplitude, phase: phase, count: count, profile: profile, gain: gain
                                )
                                buffer.withUnsafeMutableBufferPointer {
                                    WaveShape.samples(amplitude: amplitude, phase: phase, envelope: envelope, gain: gain, into: $0)
                                }
                                let wrapped = WaveShape.samples(
                                    layer: layer, amplitude: amplitude, phase: phase, count: count, profile: profile, gain: gain
                                )
                                #expect(buffer.map(\.bitPattern) == legacy.map(\.bitPattern))
                                #expect(wrapped.map(\.bitPattern) == legacy.map(\.bitPattern))
                            }
                        }
                    }
                }
            }
        }
        #expect(WaveShape.samples(layer: .mid, amplitude: 1, phase: Self.phases[1], count: 0).isEmpty)
        #expect(WaveShape.Envelope(layer: .mid, count: -3, profile: .panel).count == 0)
    }

    /// Буфер можно нарезать: точки каждой линии пишутся в свой кусок одного массива.
    @Test func samplesFillRebasedSlices() {
        let envelopes = WaveLayer.allCases.map { WaveShape.Envelope(layer: $0, count: 64, profile: .wing) }
        var all = [Float](repeating: 0, count: 64 * 3)
        all.withUnsafeMutableBufferPointer { buffer in
            for (index, envelope) in envelopes.enumerated() {
                let slice = UnsafeMutableBufferPointer(rebasing: buffer[(index * 64)..<((index + 1) * 64)])
                WaveShape.samples(amplitude: 0.6, phase: Self.phases[3], envelope: envelope, gain: 1.2, into: slice)
            }
        }
        for layer in WaveLayer.allCases {
            let expected = WaveShape.samples(layer: layer, amplitude: 0.6, phase: Self.phases[3], count: 64, gain: 1.2)
            #expect(Array(all[(layer.rawValue * 64)..<((layer.rawValue + 1) * 64)]) == expected)
        }
    }

    @Test func stopsIntoBufferMatchLegacyBitForBit() {
        let palettes: [[RGBColor]] = [
            [], PaletteExtractor.fallback, WavePreset.sunset.colors, WavePreset.mono.colors,
            [RGBColor(hex: 0x336699)], WaveAppearance.customPalette(RGBColor(hex: 0x7A5CFF)),
        ]
        let levels: [Float] = [0, 0.01, 0.2, 0.35, 0.9, 1, 3, .nan]
        let times: [Double] = [0, 1.25, 33.3, 1e7, -4, .infinity]
        for profile in WaveProfile.allCases {
            let locationSets = [WavePaint.locations(for: profile), [0, 0.5, 1], [-0.2, .nan, 1.4]]
            for locations in locationSets {
                var buffer = [WavePaint.Stop](
                    repeating: WavePaint.Stop(location: -1, color: RGBColor(hex: 0), opacity: -1), count: locations.count
                )
                for palette in palettes {
                    for layer in WaveLayer.allCases {
                        for level in levels {
                            for time in times {
                                let legacy = Self.legacyStops(
                                    palette: palette, layer: layer, level: level, time: time, locations: locations, profile: profile
                                )
                                buffer.withUnsafeMutableBufferPointer {
                                    WavePaint.stops(
                                        palette: palette, layer: layer, level: level, time: time, locations: locations,
                                        profile: profile, into: $0
                                    )
                                }
                                let wrapped = WavePaint.stops(
                                    palette: palette, layer: layer, level: level, time: time, locations: locations, profile: profile
                                )
                                #expect(Self.bits(buffer) == Self.bits(legacy))
                                #expect(Self.bits(wrapped) == Self.bits(legacy))
                            }
                        }
                    }
                }
            }
        }
    }

    private static func bits(_ stops: [WavePaint.Stop]) -> [[UInt64]] {
        stops.map { stop in
            [
                stop.location.bitPattern, UInt64(stop.color.r.bitPattern), UInt64(stop.color.g.bitPattern),
                UInt64(stop.color.b.bitPattern), UInt64(stop.opacity.bitPattern),
            ]
        }
    }

    // MARK: - Образец: функции до 1.1

    private static func legacySamples(
        layer: WaveLayer, amplitude: Float, phase: WavePhase, count: Int, profile: WaveProfile, gain: Double
    ) -> [Float] {
        guard count > 0 else { return [] }
        let offsets: [Double] = [0, 2.1, 4.2]
        let swing = (gain.isFinite ? max(gain, 0) : 1) * (profile == .wing ? WaveShape.wingGain : 1)
        let index = layer.rawValue
        let p = offsets[index]
        let k = log(0.5) / log(WaveShape.peaks[index])
        let amp = Double(min(max(amplitude, 0), 1))
        let carrierPhase = phase.carrier.isFinite ? phase.carrier : 0
        let harmonicPhase = phase.harmonic.isFinite ? phase.harmonic : 0
        let denominator = Double(max(count - 1, 1))
        let twoPi = 2 * Double.pi

        let c: Double, h: Double
        switch profile {
        case .wing:
            c = WaveShape.wingCarriers[index]
            h = WaveShape.wingHarmonics[index]
        case .panel:
            c = WaveShape.panelCarriers[index]
            h = WaveShape.panelHarmonics[index]
        }

        return (0..<count).map { i in
            let t = Double(i) / denominator
            let u: Double
            let envelope: Double
            switch profile {
            case .wing:
                u = t
                envelope = pow(max(0, sin(Double.pi * pow(u, k))), 1.5)
            case .panel:
                let x = 2 * t - 1
                u = min((x * x + WaveShape.centerSoftness * WaveShape.centerSoftness).squareRoot(), 1)
                let body = WaveShape.panelFloor + (1 - WaveShape.panelFloor) * sin(Double.pi * pow(u, k))
                envelope = body * WavePaint.smoothstep(1, WaveShape.panelTaperStart, u)
            }
            let carrier = (1 - h) * sin(twoPi * c * u - carrierPhase + p) + h * sin(twoPi * 2.3 * c * u - harmonicPhase)
            let y = amp * envelope * carrier
            return Float(WaveShape.softLimit(swing * y))
        }
    }

    private static func legacyStops(
        palette: [RGBColor], layer: WaveLayer, level: Float, time: Double, locations: [Double], profile: WaveProfile
    ) -> [WavePaint.Stop] {
        typealias P = WavePaint
        let colors = P.distinct(palette.isEmpty ? PaletteExtractor.fallback : palette)
        let index = layer.rawValue
        let own = colors[index % colors.count]
        let next = colors[(index + 1) % colors.count]
        let lightnessShift = P.layerLightness[index]

        let level = level.isFinite ? min(max(level, 0), 1) : 0
        let chroma = P.restChroma + (1 - P.restChroma) * P.smoothstep(P.chromaRange.from, P.chromaRange.to, level)
        let opacity = (P.restOpacity + (P.fullOpacity - P.restOpacity) * P.smoothstep(0, P.opacityKnee, level))
            * P.layerOpacity[index]
        let shift = time.isFinite ? (P.flowSpeed * time).truncatingRemainder(dividingBy: 1) : 0

        return locations.map { raw in
            let location = raw.isFinite ? min(max(raw, 0), 1) : 0
            let u: Double
            let fadeIn: Double
            switch profile {
            case .wing:
                u = location
                fadeIn = P.fadeInStart + (1 - P.fadeInStart) * P.smoothstep(0, P.fadeInWidth, u)
            case .panel:
                u = abs(2 * location - 1)
                fadeIn = 1
            }
            let weight = Float(0.5 - 0.5 * cos(2 * Double.pi * (u - shift)))
            let lab = OKLab(
                l: min(own.l + (next.l - own.l) * weight + lightnessShift, P.maxLightness),
                a: (own.a + (next.a - own.a) * weight) * chroma,
                b: (own.b + (next.b - own.b) * weight) * chroma
            )
            let fadeOut = P.smoothstep(1, P.fadeOutStart, u)
            return P.Stop(location: location, color: RGBColor(oklab: lab), opacity: opacity * Float(fadeIn * fadeOut))
        }
    }
}
