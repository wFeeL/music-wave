import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--replay") {
    exit(Replay.run(arguments: arguments))
}
exit(WaveEval.run(arguments: arguments))
