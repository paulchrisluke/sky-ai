import Foundation

enum EnvLoader {
    static func load(from fileURL: URL) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let idx = line.firstIndex(of: "="), idx > line.startIndex else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...])
            if key.isEmpty { continue }
            if ProcessInfo.processInfo.environment[key] == nil {
                setenv(key, value, 1)
            }
        }
    }
}
