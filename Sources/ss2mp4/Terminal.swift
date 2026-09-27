import Darwin
import Foundation

// MARK: - Terminal output

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

final class ProgressLine {
    let label: String
    let isTTY = isatty(STDOUT_FILENO) != 0
    let started = Date()
    let mediaSeconds: Double
    var lastPrint = Date.distantPast
    var lastBucket = -1

    init(label: String, mediaSeconds: Double) {
        self.label = label
        self.mediaSeconds = mediaSeconds
    }

    func update(_ fraction: Double) {
        let f = min(max(fraction, 0), 1)
        let elapsed = Date().timeIntervalSince(started)
        let speed = elapsed > 0 ? f * mediaSeconds / elapsed : 0
        let eta = f > 0.01 ? elapsed * (1 - f) / f : 0
        if isTTY {
            guard Date().timeIntervalSince(lastPrint) > 0.25 else { return }
            lastPrint = Date()
            let filled = Int(f * 24)
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 24 - filled)
            print(String(format: "\r  %@ %3.0f%%  %4.1fx  ETA %@   ", bar, f * 100, speed, formatDuration(eta)), terminator: "")
            fflush(stdout)
        } else {
            let bucket = Int(f * 10)
            guard bucket > lastBucket else { return }
            lastBucket = bucket
            print(String(format: "  %3.0f%%  %4.1fx", f * 100, speed))
        }
    }

    func clear() {
        if isTTY {
            print("\r" + String(repeating: " ", count: 60) + "\r", terminator: "")
            fflush(stdout)
        }
    }
}
