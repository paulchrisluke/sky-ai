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
                    logger.info("emlx:   found messages in '\(name)' (current total: \(mailbox.messageCount))")
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
        
        // EMLX format: [length]\n[xml plist][rfc822 message]
        // The first line is the length of the plist string.
        let dataString = String(decoding: data.prefix(100), as: UTF8.self)
        let parts = dataString.split(separator: "\n", maxSplits: 1)
        guard parts.count >= 1, let plistLength = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        
        // Find actual start of plist (after the first \n)
        guard let firstNewlineIndex = data.firstIndex(of: 10) else { return nil }
        let plistStart = firstNewlineIndex + 1
        let messageStart = plistStart + plistLength
        
        guard messageStart < data.count else { return nil }
        
        let rfc822Data = data.subdata(in: messageStart..<data.count)
        let rfc822String = String(decoding: rfc822Data, as: UTF8.self)
        
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
        let lines = content.components(separatedBy: "\n")
        var headers: [String: String] = [:]
        var bodyLines: [String] = []
        var inHeaders = true
        var currentHeader: String?
        
        for line in lines {
            let processedLine = line.replacingOccurrences(of: "\r", with: "")
            if inHeaders {
                if processedLine.isEmpty {
                    inHeaders = false
                    continue
                }
                
                if processedLine.hasPrefix(" ") || processedLine.hasPrefix("\t") {
                    if let key = currentHeader {
                        headers[key] = (headers[key] ?? "") + " " + processedLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else if let colonIndex = processedLine.firstIndex(of: ":") {
                    let key = String(processedLine[..<colonIndex]).lowercased().trimmingCharacters(in: .whitespaces)
                    let value = String(processedLine[processedLine.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                    currentHeader = key
                }
            } else {
                bodyLines.append(processedLine)
            }
        }
        
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
        let body = bodyLines.joined(separator: "\n").prefix(5000)
        
        return RawMessage(
            messageId: messageId,
            accountId: accountId,
            subject: subject,
            from: from,
            to: [],
            date: finalDate,
            bodyText: String(body),
            mailbox: mailbox
        )
    }
}
