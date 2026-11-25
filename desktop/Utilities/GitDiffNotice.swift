import Foundation

enum GitDiffNotice {
    static let marker = "\u{1F}golens-diff-notice\u{1F}"
    static let maxUntrackedFileBytes = 1 << 20
    static let maxDiffOutputBytes = 4 << 20

    static func make(_ text: String) -> String {
        marker + text
    }

    static func message(in raw: String) -> String? {
        raw.hasPrefix(marker) ? String(raw.dropFirst(marker.count)) : nil
    }

    static func headerOnlyMessage(in raw: String) -> String? {
        guard !raw.isEmpty, !raw.hasPrefix(marker), !raw.hasPrefix("@@ "), !raw.contains("\n@@ ") else {
            return nil
        }
        if raw.contains("\nBinary files ") || raw.hasPrefix("Binary files ") || raw.contains("\nGIT binary patch") || raw.hasPrefix("GIT binary patch") {
            return "Binary files differ and can’t be compared as text."
        }
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        func headerValue(_ prefix: String, unquote: Bool = false) -> String? {
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return unquote ? unquoteGitHeaderPath(value) : value
        }
        if let oldMode = headerValue("old mode "), let newMode = headerValue("new mode ") {
            return "File permissions changed from \(oldMode) to \(newMode)."
        }
        if let fromPath = headerValue("rename from ", unquote: true), let toPath = headerValue("rename to ", unquote: true) {
            return "Renamed from \(fromPath) to \(toPath) with no content changes."
        }
        if let fromPath = headerValue("copy from ", unquote: true), let toPath = headerValue("copy to ", unquote: true) {
            return "Copied from \(fromPath) to \(toPath) with no content changes."
        }
        if raw.contains("Subproject commit ") {
            return "Submodule commit changed."
        }
        if headerValue("new file mode ") != nil {
            return "Empty file added."
        }
        if headerValue("deleted file mode ") != nil {
            return "Empty file deleted."
        }
        return nil
    }

    private static func unquoteGitHeaderPath(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        let inner = Array(value.dropFirst().dropLast().utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(inner.count)
        var i = 0
        while i < inner.count {
            let b = inner[i]
            if b == 0x5C, i + 1 < inner.count {
                let next = inner[i + 1]
                switch next {
                case 0x22: bytes.append(0x22); i += 2
                case 0x5C: bytes.append(0x5C); i += 2
                case 0x74: bytes.append(0x09); i += 2
                case 0x6E: bytes.append(0x0A); i += 2
                case 0x72: bytes.append(0x0D); i += 2
                case 0x30...0x37:
                    var oct = UInt16(next - 0x30)
                    var consumed = 2
                    while consumed < 4, i + consumed < inner.count, (0x30...0x37).contains(inner[i + consumed]) {
                        oct = oct * 8 + UInt16(inner[i + consumed] - 0x30)
                        consumed += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: oct))
                    i += consumed
                default:
                    bytes.append(next)
                    i += 2
                }
            } else {
                bytes.append(b)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func formattedSize(_ bytes: Int) -> String {
        UserMessage.byteCount(Int64(bytes))
    }

    static var untrackedFolder: String {
        make("This untracked folder isn’t listed file by file. Stage it to add everything inside.")
    }

    static var tooLargeDiff: String {
        make("This diff is larger than \(formattedSize(maxDiffOutputBytes)), so it isn’t shown. Open the file to review it.")
    }

    static var vmUnavailable: String {
        make("The Linux VM isn’t ready, so Git couldn’t compare this file. Try again in a moment.")
    }

    static func untrackedNotice(forPath path: String, maxBytes: Int = maxUntrackedFileBytes) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return untrackedFolder
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let binary = isBinaryFile(atPath: path)
        if binary {
            return make("Binary file, \(formattedSize(size)). There’s no text diff to show.")
        }
        if size > maxBytes {
            return make("This file is \(formattedSize(size)), too large to show as a diff. Open it to review its contents.")
        }
        return nil
    }

    static func isBinaryFile(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8000) else { return false }
        return head.contains(0)
    }
}
