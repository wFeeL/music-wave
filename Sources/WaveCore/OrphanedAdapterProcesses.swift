import Foundation

/// Процессы адаптера Now Playing, пережившие прошлый запуск WaveFeels (падение или
/// принудительный выход): их родитель launchd (pid 1), а в командной строке скрипт адаптера
/// этого бандла. Поток такого процесса живет, пока следующая запись не упрется в закрытый
/// пайп, а без музыки это может длиться долго, и каждый новый запуск добавлял бы еще один.
public enum OrphanedAdapterProcesses {
    /// pid таких процессов в выводе `ps -axww -o pid=,ppid=,command=`. Скрипт должен стоять в
    /// командной строке отдельным словом; `ownPID` не берется никогда.
    public static func pids(psOutput: String, scriptPath: String, excluding ownPID: Int32) -> [Int32] {
        guard !scriptPath.isEmpty else { return [] }
        var result: [Int32] = []
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let parent = Int32(fields[1]),
                  parent == 1, pid != ownPID,
                  mentions(String(fields[2]), path: scriptPath)
            else { continue }
            result.append(pid)
        }
        return result
    }

    /// Перед SIGTERM: строка `ps -o ppid=,command= -p <pid>` все еще про процесс адаптера без
    /// родителя (родитель launchd, скрипт этого бандла отдельным словом). Между двумя вызовами
    /// `ps` процесс мог выйти, а его pid достаться другому; пустая строка значит, что процесса нет.
    public static func stillOrphan(psLine: String, scriptPath: String) -> Bool {
        guard !scriptPath.isEmpty else { return false }
        let fields = psLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard fields.count == 2, let parent = Int32(fields[0]), parent == 1 else { return false }
        let command = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return mentions(command, path: scriptPath)
    }

    /// `path` есть в `command` и за ним конец строки или пробел.
    private static func mentions(_ command: String, path: String) -> Bool {
        var rest = command[...]
        while let range = rest.range(of: path) {
            let after = range.upperBound
            if after == rest.endIndex || rest[after] == " " { return true }
            rest = rest[after...]
        }
        return false
    }
}
