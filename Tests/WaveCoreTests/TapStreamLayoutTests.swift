import Testing
@testable import WaveCore

/// Потоки tap во входе агрегата: идут в конце списка, после входов подустройства (микрофон
/// AirPods или гарнитуры). Если их нельзя отделить, захват не запускается.
struct TapStreamLayoutTests {
    @Test func speakersWithoutInputsGiveTheOnlyStream() {
        #expect(TapStreamLayout.firstTapStream(channels: [2], subDeviceInputStreams: 0, tapChannels: 2) == 0)
    }

    @Test func headsetMicrophoneComesFirst() {
        #expect(TapStreamLayout.firstTapStream(channels: [1, 2], subDeviceInputStreams: 1, tapChannels: 2) == 1)
    }

    @Test func unreadableSubDevicesStillSkipStereoMicrophone() {
        // Раньше непрочитанный список подустройств давал 0 и микрофон попадал в сведение.
        #expect(TapStreamLayout.firstTapStream(channels: [2, 2], subDeviceInputStreams: nil, tapChannels: 2) == 1)
    }

    @Test func tapSplitIntoMonoStreamsIsAccumulatedFromTheEnd() {
        #expect(TapStreamLayout.firstTapStream(channels: [1, 1, 1], subDeviceInputStreams: nil, tapChannels: 2) == 1)
    }

    @Test func trailingStreamsThatOvershootTapChannelsFail() {
        #expect(TapStreamLayout.firstTapStream(channels: [1, 4], subDeviceInputStreams: nil, tapChannels: 2) == nil)
    }

    @Test func tooFewChannelsFail() {
        #expect(TapStreamLayout.firstTapStream(channels: [1], subDeviceInputStreams: nil, tapChannels: 2) == nil)
    }

    @Test func noStreamsFail() {
        #expect(TapStreamLayout.firstTapStream(channels: [], subDeviceInputStreams: 0, tapChannels: 2) == nil)
    }

    @Test func allStreamsBelongToSubDeviceFail() {
        // Подустройство заявило оба потока: потока tap нет, последний поток это микрофон.
        #expect(TapStreamLayout.firstTapStream(channels: [2, 2], subDeviceInputStreams: 2, tapChannels: 2) == nil)
    }

    @Test func channelMismatchFallsBackToKnownSubDeviceCount() {
        // Формат tap говорит о стерео, поток tap пришел моно: границу дает число входов подустройства.
        #expect(TapStreamLayout.firstTapStream(channels: [2, 1], subDeviceInputStreams: 1, tapChannels: 2) == 1)
    }

    @Test func unknownTapFormatUsesSubDeviceCount() {
        #expect(TapStreamLayout.firstTapStream(channels: [1, 2], subDeviceInputStreams: 1, tapChannels: 0) == 1)
    }

    @Test func unknownTapFormatAndUnreadableSubDevicesFail() {
        #expect(TapStreamLayout.firstTapStream(channels: [1, 2], subDeviceInputStreams: nil, tapChannels: 0) == nil)
    }

    @Test func zeroChannelStreamBeforeTapIsNotIncluded() {
        #expect(TapStreamLayout.firstTapStream(channels: [2, 0, 2], subDeviceInputStreams: nil, tapChannels: 2) == 2)
    }
}
