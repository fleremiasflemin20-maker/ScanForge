import Foundation

/// Imprime el progreso de una PhotogrammetrySession en la terminal, sobrescribiendo la línea actual.
final class ProgressReporter {
    private var lastLineLength = 0
    private var currentRequestLabel = ""

    func startRequest(label: String) {
        currentRequestLabel = label
        finishLine()
        print("→ \(label)")
    }

    func update(fraction: Double) {
        let percent = Int((fraction * 100).rounded())
        let barWidth = 30
        let filled = max(0, min(barWidth, Int(Double(barWidth) * fraction)))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
        let line = "  [\(bar)] \(percent)%"
        printInPlace(line)
    }

    func warn(_ message: String) {
        finishLine()
        print("⚠️  \(message)")
    }

    func info(_ message: String) {
        finishLine()
        print("  \(message)")
    }

    func finishLine() {
        if lastLineLength > 0 {
            print("")
            lastLineLength = 0
        }
    }

    private func printInPlace(_ line: String) {
        let padded = line.padding(toLength: max(line.count, lastLineLength), withPad: " ", startingAt: 0)
        print("\r\(padded)", terminator: "")
        fflush(stdout)
        lastLineLength = line.count
    }
}
