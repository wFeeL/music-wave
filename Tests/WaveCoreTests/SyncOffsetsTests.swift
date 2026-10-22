import Testing
import Foundation
@testable import WaveCore

struct SyncOffsetsTests {
    private let speakers = "BuiltInSpeakerDevice"
    private let airPods = "AA-BB-CC-DD-EE-FF:output"

    // MARK: - Общий сдвиг

    @Test func emptyOffsetsGiveZeroEverywhere() {
        let offsets = SyncOffsets()
        #expect(offsets.fallbackMs == 0)
        #expect(offsets.byDevice.isEmpty)
        #expect(offsets.offset(forDeviceUID: speakers) == 0)
        #expect(offsets.offset(forDeviceUID: "") == 0)
    }

    @Test func unknownDeviceUsesFallback() {
        var offsets = SyncOffsets()
        offsets.set(-20, deviceUID: "", name: "")
        offsets.set(40, deviceUID: airPods, name: "AirPods")
        #expect(offsets.fallbackMs == -20)
        #expect(offsets.offset(forDeviceUID: speakers) == -20)
        #expect(offsets.offset(forDeviceUID: "") == -20)
        #expect(offsets.offset(forDeviceUID: airPods) == 40)
    }

    @Test func emptyUIDEditsFallbackWithoutDeviceEntry() {
        var offsets = SyncOffsets()
        offsets.set(15, deviceUID: "", name: "Без имени")
        #expect(offsets.fallbackMs == 15)
        #expect(offsets.byDevice.isEmpty)
        #expect(!offsets.hasOwnOffset(forDeviceUID: ""))
    }

    // MARK: - Сдвиг устройства

    @Test func setStoresValueAndNamePerDevice() {
        var offsets = SyncOffsets()
        offsets.set(40, deviceUID: airPods, name: "AirPods")
        offsets.set(-10, deviceUID: speakers, name: "Динамики MacBook Pro")
        #expect(offsets.byDevice[airPods] == SyncOffsets.DeviceOffset(ms: 40, name: "AirPods"))
        #expect(offsets.byDevice[speakers] == SyncOffsets.DeviceOffset(ms: -10, name: "Динамики MacBook Pro"))
        #expect(offsets.fallbackMs == 0)
        #expect(offsets.hasOwnOffset(forDeviceUID: airPods))
        #expect(!offsets.hasOwnOffset(forDeviceUID: "Другое"))

        offsets.set(45, deviceUID: airPods, name: "AirPods Pro")
        #expect(offsets.byDevice[airPods] == SyncOffsets.DeviceOffset(ms: 45, name: "AirPods Pro"))
    }

    /// Значение, равное общему, остается своим: пользователь выбрал его для устройства.
    @Test func valueEqualToFallbackStaysOwn() {
        var offsets = SyncOffsets()
        offsets.set(0, deviceUID: airPods, name: "AirPods")
        #expect(offsets.hasOwnOffset(forDeviceUID: airPods))
    }

    @Test func resetReturnsDeviceToFallback() {
        var offsets = SyncOffsets()
        offsets.set(25, deviceUID: "", name: "")
        offsets.set(40, deviceUID: airPods, name: "AirPods")
        offsets.set(-10, deviceUID: speakers, name: "Динамики")
        offsets.reset(deviceUID: airPods)
        #expect(offsets.offset(forDeviceUID: airPods) == 25)
        #expect(!offsets.hasOwnOffset(forDeviceUID: airPods))
        #expect(offsets.offset(forDeviceUID: speakers) == -10)

        offsets.reset(deviceUID: "")
        offsets.reset(deviceUID: "Неизвестное")
        #expect(offsets.fallbackMs == 25)
        #expect(offsets.byDevice.count == 1)
    }

    // MARK: - Ограничения

    /// -100...100 мс, до ближайшего кратного 5.
    @Test func valuesClampToRangeAndStep() {
        #expect(SyncOffsets.range == -100...100)
        #expect(SyncOffsets.step == 5)
        #expect(SyncOffsets.clamp(250) == 100)
        #expect(SyncOffsets.clamp(-500) == -100)
        #expect(SyncOffsets.clamp(-37) == -35)
        #expect(SyncOffsets.clamp(42) == 40)
        #expect(SyncOffsets.clamp(43) == 45)
        #expect(SyncOffsets.clamp(Int.max) == 100)
        #expect(SyncOffsets.clamp(Int.min) == -100)

        var offsets = SyncOffsets(fallbackMs: 250, byDevice: [airPods: .init(ms: -37, name: "AirPods")])
        #expect(offsets.fallbackMs == 100)
        #expect(offsets.offset(forDeviceUID: airPods) == -35)
        offsets.set(-500, deviceUID: airPods, name: "AirPods")
        offsets.set(42, deviceUID: "", name: "")
        #expect(offsets.offset(forDeviceUID: airPods) == -100)
        #expect(offsets.fallbackMs == 40)
    }

    // MARK: - Перенос старого значения

    /// Старый общий сдвиг `wf.syncOffset` становится `fallbackMs`, устройства пустые.
    @Test func migratedFromLegacyValue() {
        #expect(SyncOffsets.migrated(legacyMs: nil) == SyncOffsets())
        #expect(SyncOffsets.migrated(legacyMs: -35) == SyncOffsets(fallbackMs: -35))
        #expect(SyncOffsets.migrated(legacyMs: 42).fallbackMs == 40)
        #expect(SyncOffsets.migrated(legacyMs: 250).fallbackMs == 100)
        #expect(SyncOffsets.migrated(legacyMs: 30).byDevice.isEmpty)
    }

    // MARK: - JSON

    @Test func roundTripsThroughJSON() throws {
        var offsets = SyncOffsets()
        offsets.set(-15, deviceUID: "", name: "")
        offsets.set(40, deviceUID: airPods, name: "AirPods")
        let data = try JSONEncoder().encode(offsets)
        #expect(try JSONDecoder().decode(SyncOffsets.self, from: data) == offsets)
    }

    /// Значения из хранилища проходят те же ограничения, что и присваивание.
    @Test func decodingClampsStoredValues() throws {
        let json = #"{"fallbackMs":-250,"byDevice":{"a":{"ms":37,"name":"A"},"b":{"ms":900,"name":"B"}}}"#
        let offsets = try JSONDecoder().decode(SyncOffsets.self, from: Data(json.utf8))
        #expect(offsets.fallbackMs == -100)
        #expect(offsets.offset(forDeviceUID: "a") == 35)
        #expect(offsets.offset(forDeviceUID: "b") == 100)
        #expect(offsets.byDevice["b"]?.name == "B")
    }

    /// Запись без UID в хранилище не должна прятать общий сдвиг.
    @Test func decodingDropsEmptyUID() throws {
        let json = #"{"fallbackMs":10,"byDevice":{"":{"ms":50,"name":"X"}}}"#
        let offsets = try JSONDecoder().decode(SyncOffsets.self, from: Data(json.utf8))
        #expect(offsets.byDevice.isEmpty)
        #expect(offsets.offset(forDeviceUID: "") == 10)
    }
}
