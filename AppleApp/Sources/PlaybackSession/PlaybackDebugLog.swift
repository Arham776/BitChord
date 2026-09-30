import Foundation

/// Bounded, sanitized events. Persistence has its own serial queue; callers
/// never write files on an audio callback or wait for disk while recording.
final class PlaybackDebugLog: @unchecked Sendable {
    static let shared = PlaybackDebugLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int
    private let writer = DispatchQueue(label: "BitChord.diagnostics", qos: .utility)
    private let directory: URL
    private let runFile: URL
    private let limit = 2 * 1024 * 1024
    private var observers: [NSObjectProtocol] = []

    init(capacity: Int = 80, directory: URL? = nil) {
        self.capacity = capacity
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/Diagnostics", isDirectory: true)
        self.runFile = self.directory.appendingPathComponent(String(format: "%.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".log")
        writer.async { [self] in
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let old = self.runFiles()
            for file in old.dropLast(4) { try? FileManager.default.removeItem(at: file) }
            self.append("RUN START version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "development") build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown") os=\(ProcessInfo.processInfo.operatingSystemVersionString)\n")
        }
        for name in ["NSApplicationWillTerminateNotification", "UIApplicationWillTerminateNotification"] {
            observers.append(NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: nil) { [weak self] _ in self?.markCleanExit() })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    static func sanitize(_ text: String, limit: Int? = 32768) -> String {
        var value = limit.map { String(text.prefix($0)) } ?? text
        let patterns: [(String, String)] = [
            (#"(?im)^.*(?:authorization\s*[:=]|cookie\s*[:=]|set-cookie\s*[:=]).*$"#, "<credential redacted>"),
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            (#"(?i)([\"']?(?:access_token|refresh_token|id_token|token|sapisid|sid|authUser|accountId|pageId|dataSyncId|client_secret|code)[\"']?\s*[:=]\s*[\"']?)[^\s,;\"'}]+"#, "$1<redacted>"),
            (#"https?://[^\s\"'<>]+"#, "<url redacted>"),
            (#"(?<![A-Z0-9._%+-])[A-Z0-9._%+-]{1,256}@[A-Z0-9.-]{1,253}\.[A-Z]{2,63}"#, "<email redacted>"),
            (#"/(?:Users|private|var|home|Volumes)/[^\n\"']+"#, "<path redacted>")
        ]
        for (pattern, replacement) in patterns {
            if pattern.contains("@["), !value.contains("@") { continue }
            if pattern.contains("authorization"), !value.localizedCaseInsensitiveContains("authorization"), !value.localizedCaseInsensitiveContains("cookie") { continue }
            if pattern.contains("bearer"), !value.localizedCaseInsensitiveContains("bearer") { continue }
            if pattern.contains("https?"), !value.contains("http") { continue }
            if pattern.contains("access_token"), !value.contains("="), !value.contains(":") { continue }
            if pattern.contains("Users|private"), !value.contains("/") { continue }
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
            }
        }
        return value
    }
    func record(_ message: String, about mediaId: String? = nil) {
        let value = Self.sanitize("\(Date().ISO8601Format()) \(mediaId.map { "media=\($0) " } ?? "")\(message)")
        lock.lock(); lines.append(value); if lines.count > capacity { lines.removeFirst(lines.count - capacity) }; lock.unlock()
        writer.async { [self] in append(value + "\n") }
    }
    func dump() -> String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    private func runFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            if !FileManager.default.fileExists(atPath: runFile.path) { try data.write(to: runFile, options: .atomic); return }
            let size = ((try FileManager.default.attributesOfItem(atPath: runFile.path)[.size]) as? NSNumber)?.intValue ?? 0
            if size + data.count > limit {
                let old = try Data(contentsOf: runFile)
                var compact = Data(old.prefix(512)); compact += Data("\nEVENT HISTORY COMPACTED\n".utf8)
                compact += old.suffix(limit / 2); compact += data
                try compact.write(to: runFile, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: runFile); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            }
        } catch { /* Disk failure never interrupts transport. */ }
    }
    func markCleanExit() { writer.sync { append("RUN CLEAN EXIT\n") } }
    func clearHistory() {
        writer.sync { for file in runFiles() { try? FileManager.default.removeItem(at: file) }; append("RUN START history cleared\n") }
        lock.lock(); lines.removeAll(); lock.unlock()
    }
    func saveReport(snapshot: String) throws -> URL {
        try writer.sync {
            var report = "BitChord diagnostic report\n\(Date().ISO8601Format())\n\nENGINE SNAPSHOT\n\(Self.sanitize(snapshot))\n"
            for file in runFiles() {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "unavailable"
                let state = file == runFile ? "current" : (text.contains("RUN CLEAN EXIT") ? "clean exit" : "interrupted; no clean-exit marker")
                report += "\nRUN \(file.lastPathComponent) (\(state))\n" + Self.sanitize(text, limit: nil)
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("BitChord-Diagnostics-\(UUID().uuidString).txt")
            try Data(report.utf8).write(to: target, options: .atomic)
            return target
        }
    }
}
