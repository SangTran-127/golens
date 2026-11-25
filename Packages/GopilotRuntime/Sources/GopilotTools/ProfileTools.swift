import Foundation
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis

extension ExecutionKit {
    static let speedupNote = "none: a profile share is an observation about this artifact, not a measured speedup. Confirm any optimization with a timed benchmark comparison."

    @discardableResult
    func refreshProfiles() async -> Int {
        guard let source = context.backends.profiles else { return 0 }
        var skipped = 0
        for info in await source.attachedProfiles() {
            guard let payload = await source.payload(sourceKey: info.sourceKey) else { continue }
            guard !payload.contentSha256.isEmpty, let kind = ProfileRecord.kind(mode: payload.mode, sampleType: payload.sampleType) else {
                skipped += 1
                continue
            }
            let id = ProfileRecord.deriveID(contentSHA256: payload.contentSha256, kind: kind, sampleType: payload.sampleType)
            guard case .unknown = await context.profiles.lookup(id) else { continue }
            guard let record = try? ProfileRecord.make(from: payload, metadata: info.metadata, mapping: info.mapping, capturedAt: info.capturedAt) else {
                skipped += 1
                continue
            }
            _ = await context.profiles.add(record)
        }
        return skipped
    }

    func profileUnavailable(callID: String, tool: String) -> ToolResultEnvelope {
        envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "\(tool) has no profile source in this host."])
    }

    func profileError(_ error: Error, callID: String) -> ToolResultEnvelope {
        switch error as? HotspotError {
        case .profileUnknown:
            return failure(callID: callID, code: .notFound, message: "No profile with this ID is attached. Use list_profiles.")
        case .profileExpired:
            return failure(callID: callID, code: .staleContext, message: "This profile's data has expired and was released. Ask the user to attach it again; it will get a new ID if the content differs.")
        default:
            return failure(callID: callID, code: .unavailable, message: "The profile could not be read.")
        }
    }

    func share(_ value: Int64, of total: Int64) -> Any {
        total > 0 ? Double(value) / Double(total) : NSNull()
    }

    func listProfiles() -> ExecTool {
        makeTool(
            name: "list_profiles",
            description: "List the profiles the user attached to this workspace (at most 20 per page) with their immutable IDs, kind, sample type, unit, totals, mapping confidence and completeness. Use the IDs with profile_hotspots and profile_frame.",
            parameters: ToolSchemas.object(properties: [ToolSchemas.cursor, ToolSchemas.limit(20)])
        ) { callID, args in
            guard context.backends.profiles != nil else { return profileUnavailable(callID: callID, tool: "list_profiles") }
            guard let offset = cursorOffset(args["cursor"]?.stringValue) else {
                return failure(callID: callID, code: .invalidArguments, message: "cursor is not valid.")
            }
            let limit = args["limit"]?.intValue ?? 20
            let skipped = await refreshProfiles()
            let snapshot = await context.snapshot()
            let all = await context.profiles.list()
            guard !all.isEmpty else {
                var fields: [String: Any] = ["message": "No profile is attached. Ask the user to attach one.", "complete": true]
                if skipped > 0 { fields["unsupportedAttachments"] = skipped }
                return envelope(callID: callID, outcome: "empty", code: nil, retryable: false, snapshotID: snapshot.id, fields: fields)
            }
            var items: [[String: Any]] = []
            for record in all.dropFirst(offset).prefix(limit) {
                var expired = false
                if case .expired = await context.profiles.lookup(record.id) { expired = true }
                let reasons = expired ? [] : HotspotView.make(record: record, limit: 1).incompleteReasons
                items.append([
                    "profileID": record.id,
                    "kind": record.kind.rawValue,
                    "sampleType": record.sampleType,
                    "unit": record.unit,
                    "totalValue": record.totalValue,
                    "totalSampleCount": record.sampleCount,
                    "durationNanos": record.durationNanos.map { $0 as Any } ?? NSNull(),
                    "mapping": record.mapping.rawValue,
                    "unknownMetadata": record.metadata.unknownFieldNames,
                    "expired": expired,
                    "complete": !expired && reasons.isEmpty,
                    "incompleteReasons": reasons.map { JSONText.clip($0.description, 200) },
                    "capturedAt": ISO8601DateFormatter().string(from: record.capturedAt)
                ])
            }
            var base: [String: Any] = ["total": all.count, "idsAreImmutable": true]
            if skipped > 0 { base["unsupportedAttachments"] = skipped }
            let shown = ItemFit.shownCount(base: base, key: "profiles", items: items)
            var fields = base
            fields["profiles"] = Array(items.prefix(shown))
            let next = offset + shown
            let hasMore = next < all.count
            return await self.found(callID: callID, toolName: "list_profiles", kind: .profile, snapshotID: snapshot.id, fields: fields, truncated: hasMore, nextCursor: hasMore ? String(next) : nil)
        }
    }

    func profileHotspots() -> ExecTool {
        makeTool(
            name: "profile_hotspots",
            description: "Rank functions of one attached profile by flat or cumulative value (at most 50 per page). Values keep the profile's own sample type, unit and denominator; cumulative values overlap and never add up. Results separate observations from inferences, flag incomplete data and never claim a speedup.",
            parameters: ToolSchemas.object(properties: [
                #""profileID":{"type":"string","minLength":1,"maxLength":64}"#,
                #""metric":{"type":"string","enum":["flat","cum"]}"#,
                ToolSchemas.cursor, ToolSchemas.limit(50)
            ], required: ["profileID"])
        ) { callID, args in
            guard context.backends.profiles != nil else { return profileUnavailable(callID: callID, tool: "profile_hotspots") }
            guard let offset = cursorOffset(args["cursor"]?.stringValue) else {
                return failure(callID: callID, code: .invalidArguments, message: "cursor is not valid.")
            }
            let profileID = args["profileID"]?.stringValue ?? ""
            let ordering: HotspotOrdering = args["metric"]?.stringValue == "cum" ? .cumulative : .flat
            let limit = args["limit"]?.intValue ?? 20
            await refreshProfiles()
            let lookup = await context.profiles.lookup(profileID)
            let view: HotspotView
            do { view = try HotspotView.make(lookup: lookup, ordering: ordering, offset: offset, limit: limit) } catch {
                return profileError(error, callID: callID)
            }
            guard case .found(let record) = lookup else { return profileError(HotspotError.profileUnknown, callID: callID) }
            let snapshot = await context.snapshot()
            let summary = ProfileEvidenceBuilder.summarize(view: view, record: record, topCount: 3)
            let rows: [[String: Any]] = view.rows.map { row in
                [
                    "frameID": row.frameID,
                    "function": redact(JSONText.clip(row.function, 200)),
                    "file": redact(JSONText.clip(row.file, 200)),
                    "line": row.line,
                    "flat": row.flat,
                    "cum": row.cum,
                    "flatShare": JSONText.finite(row.flatShare),
                    "cumShare": JSONText.finite(row.cumShare),
                    "isRecursive": row.isRecursive
                ]
            }
            let base: [String: Any] = [
                "profileID": view.profileID,
                "kind": view.kind.rawValue,
                "sampleType": view.sampleType,
                "unit": view.unit,
                "denominator": view.denominator,
                "denominatorMeaning": "total \(view.sampleType) in \(view.unit) over the whole profile",
                "totalSampleCount": view.totalSampleCount,
                "ordering": view.ordering == .flat ? "flat" : "cum",
                "totalRowCount": view.totalRowCount,
                "offset": view.offset,
                "complete": !view.incomplete,
                "incompleteReasons": view.incompleteReasons.map { JSONText.clip($0.description, 200) },
                "mapping": record.mapping.rawValue,
                "observations": summary.observations.map { JSONText.clip(redact($0), 420) },
                "inferences": summary.inferences.map { JSONText.clip(redact($0), 420) },
                "limitations": summary.limitations.map { JSONText.clip(redact($0), 300) },
                "speedupClaim": Self.speedupNote
            ]
            let shown = ItemFit.shownCount(base: base, key: "rows", items: rows)
            var fields = base
            fields["rows"] = Array(rows.prefix(shown))
            let next = view.offset + shown
            let hasMore = next < view.totalRowCount
            return await self.found(callID: callID, toolName: "profile_hotspots", kind: .profile, snapshotID: snapshot.id, fields: fields, truncated: hasMore, nextCursor: hasMore ? String(next) : nil)
        }
    }

    func profileFrame() -> ExecTool {
        makeTool(
            name: "profile_frame",
            description: "Show one function of an attached profile by frame ID: its flat and cumulative value with unit and denominator, retained callers and callees, and the source mapping confidence. Never claims a speedup.",
            parameters: ToolSchemas.object(properties: [
                #""profileID":{"type":"string","minLength":1,"maxLength":64}"#,
                #""frameID":{"type":"string","minLength":1,"maxLength":64}"#
            ], required: ["profileID", "frameID"])
        ) { callID, args in
            guard context.backends.profiles != nil else { return profileUnavailable(callID: callID, tool: "profile_frame") }
            let profileID = args["profileID"]?.stringValue ?? ""
            let frameID = args["frameID"]?.stringValue ?? ""
            await refreshProfiles()
            let record: ProfileRecord
            switch await context.profiles.lookup(profileID) {
            case .unknown: return profileError(HotspotError.profileUnknown, callID: callID)
            case .expired(let stripped): return profileError(HotspotError.profileExpired(stripped.id), callID: callID)
            case .found(let found): record = found
            }
            guard let frame = record.frame(frameID) else {
                return failure(callID: callID, code: .notFound, message: "No frame with this ID exists in profile \(profileID).")
            }
            let snapshot = await context.snapshot()
            let byFunction = Dictionary(record.frames.map { ($0.function, $0) }, uniquingKeysWith: { first, _ in first })
            func related(_ names: [String]) -> [[String: Any]] {
                names.prefix(15).map { name in
                    guard let other = byFunction[name] else { return ["function": redact(JSONText.clip(name, 200)), "retained": false] }
                    return [
                        "function": redact(JSONText.clip(name, 200)),
                        "retained": true,
                        "frameID": other.id,
                        "flat": other.flat,
                        "cum": other.cum
                    ]
                }
            }
            let pageView = hotspotPage(containing: frameID, in: record)
            let row = pageView?.rows.first { $0.frameID == frameID }
            var limitations = pageView.map { ProfileEvidenceBuilder.summarize(view: $0, record: record, topCount: 1).limitations } ?? []
            if record.truncation.truncated {
                limitations.append("callers and callees outside the retained entries are not listed")
            }
            var fields: [String: Any] = [
                "profileID": record.id,
                "frameID": frame.id,
                "function": redact(JSONText.clip(frame.function, 200)),
                "file": redact(JSONText.clip(frame.file, 200)),
                "line": frame.line,
                "kind": record.kind.rawValue,
                "sampleType": record.sampleType,
                "unit": record.unit,
                "denominator": record.totalValue,
                "flat": frame.flat,
                "cum": frame.cum,
                "flatShare": share(frame.flat, of: record.totalValue),
                "cumShare": share(frame.cum, of: record.totalValue),
                "callers": related(frame.callers),
                "callees": related(frame.children),
                "omittedCallers": max(0, frame.callers.count - 15),
                "omittedCallees": max(0, frame.children.count - 15),
                "mapping": record.mapping.rawValue,
                "mappingNote": record.mapping == .verified ? "The source mapping was verified against the current files." : "Source mapping is \(record.mapping.rawValue): the file and line may not be the code that ran.",
                "complete": !HotspotView.make(record: record, limit: 1).incomplete,
                "limitations": limitations.map { JSONText.clip(redact($0), 300) },
                "speedupClaim": Self.speedupNote,
                "observationLabel": ProfileEvidenceBuilder.observationLabel
            ]
            if let row { fields["isRecursive"] = row.isRecursive }
            var refs: [SourceRef] = []
            if record.mapping == .verified, !frame.file.isEmpty, PatchValidator.lexicalPathIssue(frame.file) == nil {
                refs.append(SourceRef(workspaceID: context.workspaceID, path: frame.file, range: SourceRange(startLine: max(0, frame.line - 1), startCharacter: 0, endLine: max(0, frame.line - 1), endCharacter: 0)))
            }
            return await self.found(callID: callID, toolName: "profile_frame", kind: .profile, refs: refs, snapshotID: snapshot.id, fields: fields)
        }
    }

    func hotspotPage(containing frameID: String, in record: ProfileRecord) -> HotspotView? {
        var offset = 0
        while offset < record.frames.count {
            let view = HotspotView.make(record: record, ordering: .flat, offset: offset, limit: HotspotView.maxLimit)
            if view.rows.contains(where: { $0.frameID == frameID }) { return view }
            offset += HotspotView.maxLimit
        }
        return nil
    }
}
