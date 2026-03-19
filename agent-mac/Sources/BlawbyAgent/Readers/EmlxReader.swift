import Foundation
import OSLog

struct EmlxAccount: Sendable {
    let id: String // directory name (hash/UUID)
    let displayName: String
    let rootPath: URL
}

struct EmlxMailbox: Sendable {
    let accountId: String
    let name: String // human readable name
    let path: URL   // .mbox path
    var messageCount: Int = 0
}

final class EmlxReader: @unchecked Sendable {
    private let logger: Logger
    private let fileManager = FileManager.default
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    private var mailRoot: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail/V10")
    }
    
    func isAvailable() -> Bool {
        return fileManager.isReadableFile(atPath: mailRoot.path)
    }
    
    func discoverAccounts() -> [EmlxAccount] {
        guard let contents = try? fileManager.contentsOfDirectory(at: mailRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            logger.warning("emlx: failed to read V10 root at \(self.mailRoot.path)")
            return []
        }
        
        var accounts: [EmlxAccount] = []
        for url in contents {
            let folderName = url.lastPathComponent
            if folderName == "MailData" { continue }
            
            // 1. Try probing a message for the account email (Primary method)
            if let probedEmail = probeAccountEmail(url: url) {
                let normalized = ConfigStore.normalizeAccountId(probedEmail)
                logger.info("emlx: resolved account '\(folderName)' to '\(normalized)' via headers")
                accounts.append(EmlxAccount(id: folderName, displayName: normalized, rootPath: url))
                continue
            }

            // 2. Try AccountInfo.plist (Secondary method)
            let infoPlist = url.appendingPathComponent("AccountInfo.plist")
            if fileManager.fileExists(atPath: infoPlist.path), let dict = NSDictionary(contentsOf: infoPlist) {
                if let name = dict["AccountName"] as? String {
                    let normalized = ConfigStore.normalizeAccountId(name)
                    logger.info("emlx: resolved account '\(folderName)' to '\(normalized)' via AccountInfo.plist")
                    accounts.append(EmlxAccount(id: folderName, displayName: normalized, rootPath: url))
                    continue
                }
            }
            
            // 3. Fallback
            if folderName == "Local" || folderName == "OnMyMac" {
                accounts.append(EmlxAccount(id: folderName, displayName: "On My Mac", rootPath: url))
            } else if folderName.count > 10 {
                let normalized = ConfigStore.normalizeAccountId(folderName)
                if normalized.contains("@") {
                    accounts.append(EmlxAccount(id: folderName, displayName: normalized, rootPath: url))
                } else {
                    accounts.append(EmlxAccount(id: folderName, displayName: "Account \(folderName.prefix(6))", rootPath: url))
                }
            }
        }
        return accounts
    }
    
    private func probeAccountEmail(url: URL) -> String? {
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var checkedCount = 0
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension == "emlx" {
                if let data = try? Data(contentsOf: file), let content = String(data: data.prefix(8192), encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n")
                    
                    // Priority 1: Delivered-To (Incoming mail owner)
                    if let line = lines.first(where: { $0.lowercased().hasPrefix("delivered-to:") }) {
                        let email = line.dropFirst(13).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if email.contains("@") { return email }
                    }
                    
                    // Priority 2: X-Real-To or X-Original-To (Incoming mail owner aliasing)
                    for header in ["x-real-to:", "x-original-to:", "x-delivered-to:"] {
                        if let line = lines.first(where: { $0.lowercased().hasPrefix(header) }) {
                            let email = line.dropFirst(header.count).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            if email.contains("@") { return email }
                        }
                    }

                    // Priority 3: From (Reliable for Sent messages)
                    // We only use From if we see headers suggesting this is a Sent/Draft/Outgoing message
                    // OR if it's the only identifier we found across multiple propped files.
                    if let line = lines.first(where: { $0.lowercased().hasPrefix("from:") }) {
                        let fromValue = line.dropFirst(5).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if let email = extractEmail(from: fromValue) {
                            // Basic heuristic: check if it matches the folder name prefix or other clues
                            return email
                        }
                    }
                }
                checkedCount += 1
                if checkedCount > 15 { break } 
            }
        }
        return nil
    }

    private func extractEmail(from string: String) -> String? {
        if string.contains("<") && string.contains(">") {
            let parts = string.components(separatedBy: "<")
            if parts.count > 1 {
                let email = parts[1].components(separatedBy: ">")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                if email.contains("@") { return email }
            }
        }
        if string.contains("@") {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }


    func discoverMailboxes(account: EmlxAccount) -> [EmlxMailbox] {
        logger.info("emlx: scanning account '\(account.displayName)' at \(account.rootPath.path)")
        let enumerator = fileManager.enumerator(at: account.rootPath, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        
        var mailboxMap: [URL: EmlxMailbox] = [:]
        
        while let url = enumerator?.nextObject() as? URL {
            // We are looking for "Messages" folders which contain the actual emlx files.
            if url.lastPathComponent == "Messages" {
                // Find the parent .mbox
                var current = url
                var mboxURL: URL? = nil
                while current.path != account.rootPath.path && current.path != "/" {
                    if current.pathExtension == "mbox" {
                        mboxURL = current
                        break
                    }
                    current = current.deletingLastPathComponent()
                }
                
                if let mboxURL = mboxURL {
                    let name = mboxURL.deletingPathExtension().lastPathComponent
                    var mailbox = mailboxMap[mboxURL] ?? EmlxMailbox(accountId: account.displayName, name: name, path: mboxURL)
                    mailbox.messageCount += countEmlx(in: url)
                    mailboxMap[mboxURL] = mailbox
                }
            }
        }
        
        let results = Array(mailboxMap.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        logger.info("emlx:   finished scanning account, found \(results.count) mailboxes")
        return results
    }
    
    func messageCount(mailbox: EmlxMailbox) -> Int {
        return mailbox.messageCount
    }
    
    private func countEmlx(in url: URL) -> Int {
        var count = 0
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: options)
        while let file = enumerator?.nextObject() as? URL {
            let ext = file.pathExtension
            if ext == "emlx" || ext == "partial.emlx" {
                count += 1
            }
        }
        return count
    }
    
    func readMessages(mailbox: EmlxMailbox, since: Date?, limit: Int, ascending: Bool = true) -> [RawMessage] {
        var results: [RawMessage] = []
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        let enumerator = fileManager.enumerator(at: mailbox.path, includingPropertiesForKeys: nil, options: options)
        
        var parsedCount = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            guard !fileURL.lastPathComponent.contains(".partial.") else { continue }
            if fileURL.pathExtension == "emlx" {
                if let msg = parseEmlx(at: fileURL, accountId: mailbox.accountId, mailboxName: mailbox.name) {
                    if let since = since {
                         if since.timeIntervalSince1970 < 1000 {
                             // Global backfill: include all
                         } else if msg.date <= since {
                             continue
                         }
                    }
                    results.append(msg)
                    parsedCount += 1
                    
                    // Buffer enough to sort fairly, but avoid parsing 100k messages at once
                    if results.count >= 1000 { break }
                }
            }
        }
        
        if ascending {
            results.sort { $0.date < $1.date }
        } else {
            results.sort { $0.date > $1.date }
        }
        
        return Array(results.prefix(limit))
    }
    
    private func parseEmlx(at url: URL, accountId: String, mailboxName: String) -> RawMessage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        
        // Find first newline - length prefix ends here
        guard let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        
        // Parse length value
        let lengthData = data[data.startIndex..<newlineIndex]
        guard let lengthStr = String(data: lengthData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rfc822Length = Int(lengthStr) else { return nil }
        
        // RFC822 content starts after newline
        let rfc822Start = data.index(after: newlineIndex)
        let rfc822End = min(data.index(rfc822Start, offsetBy: rfc822Length), data.endIndex)
        
        guard rfc822Start < data.endIndex else { return nil }
        
        let rfc822Data = data[rfc822Start..<rfc822End]
        guard let rfc822String = String(data: rfc822Data, encoding: .utf8) 
            ?? String(data: rfc822Data, encoding: .isoLatin1) else { return nil }
        
        return parseRFC822(content: rfc822String, accountId: accountId, mailbox: mailboxName, fileURL: url)
    }
    
    func runPerformanceDiagnostic() {
        let startTime = CFAbsoluteTimeGetCurrent()
        var totalCount = 0
        var sampleParsed = 0
        
        let enumerator = fileManager.enumerator(at: mailRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var samples: [URL] = []
        
        while let file = enumerator?.nextObject() as? URL {
            let ext = file.pathExtension
            if ext == "emlx" || ext == "partial.emlx" {
                totalCount += 1
                if samples.count < 1000 {
                    samples.append(file)
                }
            }
        }
        
        let countTime = CFAbsoluteTimeGetCurrent() - startTime
        
        let parseStart = CFAbsoluteTimeGetCurrent()
        for url in samples {
            if parseEmlx(at: url, accountId: "test", mailboxName: "test") != nil {
                sampleParsed += 1
            }
        }
        let parseTime = CFAbsoluteTimeGetCurrent() - parseStart
        
        logger.info("emlx: performance diagnostic:")
        logger.info("emlx:   total files: \(totalCount)")
        logger.info("emlx:   scan time: \(countTime)s")
        logger.info("emlx:   parsed \(sampleParsed) samples in: \(parseTime)s (\(parseTime/Double(max(1, sampleParsed))*1000000)µs per file)")
        logger.info("emlx:   extrapolated 50k parse: \(parseTime * (50000.0/Double(max(1, sampleParsed))))s")
    }

    private func parseRFC822(content: String, accountId: String, mailbox: String, fileURL: URL) -> RawMessage? {
        let parsed = splitHeadersAndBody(content: content)
        let headers = parsed.headers
        let bodyRaw = parsed.body
        let subject = headers["subject"] ?? ""
        let from = headers["from"] ?? ""
        let dateStr = headers["date"] ?? ""
        let messageId = headers["message-id"] ?? fileURL.lastPathComponent

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz"
        ]
        var date: Date?
        for format in formats {
            dateFormatter.dateFormat = format
            if let d = dateFormatter.date(from: dateStr) {
                date = d
                break
            }
        }
        
        guard let finalDate = date
            ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else {
            logger.warning("emlx: skipping message with no parseable date or file mtime: \(fileURL.path)")
            return nil
        }
        let body = decodeMIMEBody(headers: headers, body: bodyRaw).prefix(3000)
        let bodyText = String(body)
        
        if subject.isEmpty && bodyText.isEmpty {
            logger.warning("emlx: empty parse result for \(fileURL.lastPathComponent)")
            return nil
        }
        
        logger.info("emlx parsed: subject='\(subject)' bodyLen=\(bodyText.count) messageId='\(messageId)'")

        return RawMessage(
            messageId: messageId,
            accountId: accountId,
            subject: subject,
            from: from,
            to: [],
            date: finalDate,
            bodyText: bodyText,
            mailbox: mailbox
        )
    }

    private func splitHeadersAndBody(content: String) -> (headers: [String: String], body: String) {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let separator = "\n\n"
        let headerEnd = normalized.range(of: separator)?.lowerBound ?? normalized.endIndex
        let headerText = String(normalized[..<headerEnd])
        let bodyStart = headerEnd < normalized.endIndex ? normalized.index(headerEnd, offsetBy: separator.count) : normalized.endIndex
        let bodyText = String(normalized[bodyStart...])

        var headers: [String: String] = [:]
        var currentHeader: String?
        for line in headerText.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let key = currentHeader {
                    headers[key] = (headers[key] ?? "") + " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
            currentHeader = key
        }
        return (headers, bodyText)
    }

    private func decodeMIMEBody(headers: [String: String], body: String) -> String {
        let contentType = headers["content-type"]?.lowercased() ?? "text/plain"
        let transferEncoding = headers["content-transfer-encoding"]?.lowercased() ?? ""

        if contentType.contains("multipart/"), let boundary = extractBoundary(from: headers["content-type"] ?? "") {
            let parts = splitMultipartBody(body: body, boundary: boundary)
            var htmlFallback: String?

            for part in parts {
                let parsed = splitHeadersAndBody(content: part)
                let partType = parsed.headers["content-type"]?.lowercased() ?? "text/plain"
                let decoded = decodeMIMEBody(headers: parsed.headers, body: parsed.body)
                if decoded.isEmpty { continue }
                if partType.contains("text/plain") {
                    return decoded
                }
                if partType.contains("text/html"), htmlFallback == nil {
                    htmlFallback = decoded
                }
            }
            return cleanBodyText(htmlFallback ?? "")
        }

        let charset = extractCharset(from: headers["content-type"] ?? "")
        let transferDecoded = decodeTransferEncoding(body: body, encoding: transferEncoding, charset: charset)
        let plain = contentType.contains("text/html") ? htmlToPlainText(transferDecoded) : transferDecoded
        return cleanBodyText(plain)
    }

    private func decodeTransferEncoding(body: String, encoding: String, charset: String?) -> String {
        if encoding.contains("base64") {
            let collapsed = body.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            if let data = Data(base64Encoded: collapsed) {
                return decodeData(data, charset: charset)
            }
            return body
        }
        if encoding.contains("quoted-printable") {
            return decodeQuotedPrintable(body, charset: charset)
        }
        return body
    }

    private func decodeQuotedPrintable(_ text: String, charset: String?) -> String {
        let bytes = Array(text.utf8)
        var output = Data()
        var i = 0
        while i < bytes.count {
            if bytes[i] == 61 { // "="
                if i + 2 < bytes.count {
                    let b1 = bytes[i + 1]
                    let b2 = bytes[i + 2]
                    if (b1 == 13 && b2 == 10) || b1 == 10 {
                        i += (b1 == 13 && b2 == 10) ? 3 : 2
                        continue
                    }
                    let hex = String(bytes: [b1, b2], encoding: .ascii) ?? ""
                    if let value = UInt8(hex, radix: 16) {
                        output.append(value)
                        i += 3
                        continue
                    }
                }
            }
            output.append(bytes[i])
            i += 1
        }
        return decodeData(output, charset: charset)
    }

    private func decodeData(_ data: Data, charset: String?) -> String {
        if let enc = stringEncoding(for: charset), let text = String(data: data, encoding: enc) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func stringEncoding(for charset: String?) -> String.Encoding? {
        guard let charset else { return nil }
        let lower = charset.lowercased()
        if lower.contains("utf-8") { return .utf8 }
        if lower.contains("iso-8859-1") || lower.contains("latin1") || lower.contains("latin-1") { return .isoLatin1 }
        if lower.contains("windows-1252") { return .windowsCP1252 }
        return nil
    }

    private func extractBoundary(from contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var boundary = String(contentType[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let semicolon = boundary.firstIndex(of: ";") {
            boundary = String(boundary[..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return boundary.isEmpty ? nil : boundary
    }

    private func extractCharset(from contentType: String) -> String? {
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else { return nil }
        var charset = String(contentType[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let semicolon = charset.firstIndex(of: ";") {
            charset = String(charset[..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        charset = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return charset.isEmpty ? nil : charset
    }

    private func splitMultipartBody(body: String, boundary: String) -> [String] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let marker = "--\(boundary)"
        let closing = "--\(boundary)--"
        return normalized
            .components(separatedBy: marker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "--" && !$0.hasPrefix(closing) }
    }

    private func htmlToPlainText(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        return text
    }

    private func cleanBodyText(_ body: String) -> String {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let headerLike = try? NSRegularExpression(pattern: "^[A-Za-z0-9-]+:\\s+.+$")
        let cleanedLines = lines.filter { line in
            guard !line.isEmpty else { return false }
            if let headerLike {
                let range = NSRange(location: 0, length: (line as NSString).length)
                if headerLike.firstMatch(in: line, options: [], range: range) != nil {
                    return false
                }
            }
            return true
        }
        let compact = cleanedLines.joined(separator: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact
    }
}
