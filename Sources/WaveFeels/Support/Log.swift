import Foundation
import os

/// Логи приложения: `os.Logger` по категориям и файл `~/Library/Logs/WaveFeels/wavefeels.log`.
/// Не привязан к актору: вызывается из любого потока, кроме аудио-колбэка.
nonisolated enum Log {
    static let subsystem = "com.wfeels.wavefeels"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let nowPlaying = Logger(subsystem: subsystem, category: "nowPlaying")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Дописывает строку в файл лога. Запись идет на отдельной последовательной очереди.
    static func file(_ message: String) {
        fileWriter.append(message)
    }

    private static let fileWriter = LogFileWriter()
}

/// Пишет строки в файл лога на своей последовательной очереди, при 1 МБ переносит файл в `.1`.
private final class LogFileWriter: Sendable {
    private static let maxBytes: UInt64 = 1_048_576

    private let queue = DispatchQueue(label: "com.wfeels.wavefeels.log-file", qos: .utility)
    private let directory: URL
    private let fileURL: URL
    private let rotatedURL: URL

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WaveFeels", isDirectory: true)
        fileURL = directory.appendingPathComponent("wavefeels.log")
        rotatedURL = directory.appendingPathComponent("wavefeels.log.1")
    }

    func append(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            self.write(line)
        }
    }

    private func write(_ line: String) {
        let manager = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let attributes = try? manager.attributesOfItem(atPath: path),
               let size = (attributes[.size] as? NSNumber)?.uint64Value,
               size >= Self.maxBytes {
                try? manager.removeItem(at: rotatedURL)
                try manager.moveItem(at: fileURL, to: rotatedURL)
            }
            if !manager.fileExists(atPath: path) {
                _ = manager.createFile(atPath: path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Файловый лог вспомогательный: ошибка записи не должна мешать приложению.
        }
    }
}
