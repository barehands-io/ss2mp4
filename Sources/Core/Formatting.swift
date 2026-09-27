import Foundation

// MARK: - Formatting

func printErr(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

func describe(_ error: Error) -> String {
    if error is ConvertError { return error.localizedDescription }
    let ns = error as NSError
    var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    if let reason = ns.localizedFailureReason { text += " \(reason)" }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { text += " ← " + describe(underlying) }
    return text
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    if t >= 3600 { return "\(t / 3600)h \(String(format: "%02d", t % 3600 / 60))m" }
    if t >= 60 { return "\(t / 60)m \(String(format: "%02d", t % 60))s" }
    return "\(t)s"
}
