import Testing
import WaveCore
@testable import WaveFeels

/// Строки диагностики, которые зависят от статуса захвата.
struct AppModelDiagnosticsTests {
    /// «Источник выводит звук» показывает «да» или «нет», только пока значение обновляется.
    @Test func outputtingIsShownOnlyWhileCaptureRuns() {
        let cases: [(PipelineStatus, String)] = [
            (.capturing(.running(sampleRate: 48_000, processCount: 2)), "да"),
            (.rebuilding(attempt: 1), "да"),
            (.suspended, "да"),
            (.stopped, "нет данных"),
            (.demo, "нет данных"),
            (.starting, "нет данных"),
            (.waitingForSource, "нет данных"),
            (.retrying(attempt: 1, message: "x"), "нет данных"),
            (.paused, "нет данных"),
            (.capturing(.idle), "нет данных"),
            (.capturing(.failed("x")), "нет данных"),
        ]
        for (status, expected) in cases {
            #expect(AppModel.outputtingDescription(status: status, outputting: true) == expected, "\(status)")
        }
        #expect(AppModel.outputtingDescription(status: .capturing(.running(sampleRate: 48_000, processCount: 2)), outputting: false) == "нет")
        #expect(AppModel.outputtingDescription(status: .rebuilding(attempt: 2), outputting: false) == "нет")
        #expect(AppModel.outputtingDescription(status: .suspended, outputting: false) == "нет")
        #expect(AppModel.outputtingDescription(status: .stopped, outputting: false) == "нет данных")
    }

    /// Статус захвата берет сроки повторов из конвейера, а не стандартные 30 с.
    @Test func captureStatusShowsActualRetryInterval() {
        let timing = CaptureRecovery.Timing(startRetryPauses: [1, 2], slowRetryInterval: 45)
        #expect(AppModel.describe(.capturing(.failed("x")), timing: timing) == "ошибка: x; повтор раз в 45 с")
        #expect(AppModel.describe(.retrying(attempt: 1, message: "x"), timing: timing) == "tap не создан (x), повтор 1 из 2")
    }
}
