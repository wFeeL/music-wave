import Foundation
import WaveCore

/// `wave-eval --replay <rhythm.json>`: прогон записи ритма с устройства (`RhythmReplay`). WAV
/// берется рядом с записью, с тем же именем.
enum Replay {
    static func run(arguments: [String]) -> Int32 {
        let parsed: RhythmReplay.Arguments
        do {
            parsed = try RhythmReplay.Arguments.parse(arguments)
        } catch {
            log("wave-eval: \(error)\n\(RhythmReplay.Arguments.usage)\n")
            return 64
        }
        if parsed.help {
            print(RhythmReplay.Arguments.usage)
            return 0
        }
        let wavPath = RhythmLog.wavPath(forLogPath: parsed.logPath)
        let logData: Data
        let wavData: Data
        do {
            logData = try Data(contentsOf: URL(fileURLWithPath: parsed.logPath))
            wavData = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        } catch {
            log("wave-eval: \(error)\n")
            return 66
        }
        do {
            let report = try RhythmReplay.replay(logData: logData, wavData: wavData, options: parsed.options)
            print(report.text)
            return 0
        } catch {
            log("wave-eval: \(parsed.logPath): \(error)\n")
            return 65
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
