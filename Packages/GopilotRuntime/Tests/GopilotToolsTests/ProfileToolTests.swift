import Foundation
import Testing
import GopilotRuntime
import GopilotPolicy
import GopilotAnalysis
@testable import GopilotTools

private func profileID(_ hash: String, kind: ProfileKind = .cpu, sampleType: String = "cpu") -> String {
    ProfileRecord.deriveID(contentSHA256: hash, kind: kind, sampleType: sampleType)
}

private func hotspots(_ h: Harness, _ id: String, extra: String = "", callID: String = "hot") async throws -> ToolResultEnvelope {
    try await h.call("profile_hotspots", "{\"profileID\":\"\(id)\"\(extra)}", id: callID)
}

private func rows(_ envelope: ToolResultEnvelope) -> [[String: Any]] {
    nestedList(decode(envelope), "rows")
}

@Suite("Profile tools")
struct ProfileToolTests {
    @Test func profileIdentityIsImmutableWhenTheAttachedProfileChanges() async throws {
        try await withHarness { h in
            let a = try makePayload(hash: "aaaa", entries: simpleEntries())
            h.profileSource.attach("current", payload: a)
            let listed = try await h.call("list_profiles", "{}")
            let idA = profileID("aaaa")
            #expect(nestedList(decode(listed), "profiles").compactMap { $0["profileID"] as? String } == [idA])
            #expect(decode(listed)["idsAreImmutable"] as? Bool == true)

            let before = try await hotspots(h, idA)
            #expect(before.status == .ok)
            let beforeRows = rows(before)
            #expect(beforeRows.count == 3)
            let evidenceBefore = try #require(await h.evidence.resolve(id: before.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(evidenceBefore.kind == .profile)

            let changed = try makePayload(hash: "bbbb", total: 5000, samples: 400, entries: [
                EntrySpec(function: "other.Work", flat: 4000, cum: 5000),
                EntrySpec(function: "other.Idle", flat: 1000, cum: 1000)
            ])
            h.profileSource.attach("current", payload: changed)
            let idB = profileID("bbbb")
            let relisted = try await h.call("list_profiles", "{}", id: "list-2")
            let ids = nestedList(decode(relisted), "profiles").compactMap { $0["profileID"] as? String }
            #expect(Set(ids) == [idA, idB])
            #expect(idA != idB)

            let after = try await hotspots(h, idA, callID: "hot-2")
            #expect(decode(after)["profileID"] as? String == idA)
            #expect(rows(after).compactMap { $0["frameID"] as? String } == beforeRows.compactMap { $0["frameID"] as? String })
            #expect(rows(after).compactMap { $0["flat"] as? Int } == beforeRows.compactMap { $0["flat"] as? Int })
            #expect(decode(after)["denominator"] as? Int == 1000)

            let newer = try await hotspots(h, idB, callID: "hot-3")
            #expect(decode(newer)["denominator"] as? Int == 5000)
            #expect(rows(newer).first?["function"] as? String == "other.Work")

            h.profileSource.detach("current")
            let detached = try await hotspots(h, idA, callID: "hot-4")
            #expect(detached.status == .ok)
            #expect(decode(detached)["denominator"] as? Int == 1000)
            #expect(evidenceBefore.content.contains(idA) && !evidenceBefore.content.contains(idB))
        }
    }

    struct Measure: Sendable {
        let mode: String
        let sampleType: String
        let unit: String
        let kind: ProfileKind
        let total: Int64
        let semantics: String
    }

    static let measures: [Measure] = [
        Measure(mode: "cpu", sampleType: "cpu", unit: "nanoseconds", kind: .cpu, total: 3_000_000, semantics: "not wall-clock"),
        Measure(mode: "memory", sampleType: "alloc_space", unit: "bytes", kind: .heapAlloc, total: 8_388_608, semantics: "not live memory"),
        Measure(mode: "memory", sampleType: "inuse_space", unit: "bytes", kind: .heapInuse, total: 4_194_304, semantics: "live memory"),
        Measure(mode: "block", sampleType: "delay", unit: "nanoseconds", kind: .block, total: 900_000, semantics: "waiting on synchronization"),
        Measure(mode: "mutex", sampleType: "delay", unit: "nanoseconds", kind: .mutex, total: 120_000, semantics: "contention delay")
    ]

    @Test func unitsAndDenominatorsStayWithTheirOwnProfile() async throws {
        try await withHarness { h in
            var ids: [String: Measure] = [:]
            for (index, measure) in Self.measures.enumerated() {
                let hash = "units-\(index)"
                let payload = try makePayload(mode: measure.mode, sampleType: measure.sampleType, unit: measure.unit, hash: hash, total: measure.total, entries: [
                    EntrySpec(function: "pkg.Big", flat: measure.total * 3 / 4, cum: measure.total),
                    EntrySpec(function: "pkg.Small", flat: measure.total / 4, cum: measure.total / 4)
                ])
                h.profileSource.attach(hash, payload: payload)
                ids[profileID(hash, kind: measure.kind, sampleType: measure.sampleType)] = measure
            }
            let listed = nestedList(decode(try await h.call("list_profiles", "{}")), "profiles")
            #expect(listed.count == 5)
            #expect(Set(listed.compactMap { $0["unit"] as? String }) == ["nanoseconds", "bytes"])

            for (id, measure) in ids {
                let result = try await hotspots(h, id)
                let data = decode(result)
                #expect(data["kind"] as? String == measure.kind.rawValue)
                #expect(data["sampleType"] as? String == measure.sampleType)
                #expect(data["unit"] as? String == measure.unit)
                #expect(data["denominator"] as? Int == Int(measure.total))
                let first = try #require(rows(result).first)
                #expect(first["function"] as? String == "pkg.Big")
                #expect(first["flat"] as? Int == Int(measure.total * 3 / 4))
                #expect(first["flatShare"] as? Double == 0.75)
                let limitations = (data["limitations"] as? [String] ?? []).joined(separator: " ")
                #expect(limitations.contains(measure.semantics), "\(measure.kind): \(limitations)")
                let observations = (data["observations"] as? [String] ?? []).joined(separator: " ")
                #expect(observations.contains(measure.sampleType))
                #expect(observations.contains("do not add up to a total"))
            }
        }
    }

    @Test func recursiveFramesAreFlaggedAndCumulativeOrderingIsExplicit() async throws {
        try await withHarness { h in
            let payload = try makePayload(hash: "rec", total: 1000, entries: [
                EntrySpec(function: "pkg.Rec", flat: 200, cum: 900, children: ["pkg.Rec", "pkg.Leaf"], callers: ["pkg.Rec"]),
                EntrySpec(function: "pkg.Leaf", flat: 700, cum: 700, callers: ["pkg.Rec"]),
                EntrySpec(function: "pkg.Root", flat: 100, cum: 1000, children: ["pkg.Rec"])
            ])
            h.profileSource.attach("rec", payload: payload)
            let id = profileID("rec")
            let flat = try await hotspots(h, id)
            let flatRows = rows(flat)
            #expect(flatRows.compactMap { $0["function"] as? String } == ["pkg.Leaf", "pkg.Rec", "pkg.Root"])
            #expect(flatRows.first { $0["function"] as? String == "pkg.Rec" }?["isRecursive"] as? Bool == true)
            #expect(flatRows.first { $0["function"] as? String == "pkg.Leaf" }?["isRecursive"] as? Bool == false)
            #expect(decode(flat)["ordering"] as? String == "flat")

            let cum = try await hotspots(h, id, extra: #","metric":"cum""#, callID: "cum")
            #expect(rows(cum).compactMap { $0["function"] as? String } == ["pkg.Root", "pkg.Rec", "pkg.Leaf"])
            #expect(decode(cum)["ordering"] as? String == "cum")
            let cumSum = rows(cum).compactMap { $0["cum"] as? Int }.reduce(0, +)
            #expect(cumSum > 1000)
            #expect(((decode(cum)["observations"] as? [String]) ?? []).contains { $0.contains("overlap") && $0.contains("do not add up") })
        }
    }

    @Test func truncatedSkippedAndEmptyProfilesAreFlaggedIncomplete() async throws {
        try await withHarness { h in
            h.profileSource.attach("trunc", payload: try makePayload(hash: "trunc", truncated: true, before: 900, entries: simpleEntries()))
            h.profileSource.attach("skipped", payload: try makePayload(hash: "skipped", skipped: 7, entries: simpleEntries()))
            h.profileSource.attach("empty", payload: try makePayload(hash: "empty", total: 0, samples: 0, entries: []))
            h.profileSource.attach("whole", payload: try makePayload(hash: "whole", entries: simpleEntries()))

            let trunc = decode(try await hotspots(h, profileID("trunc")))
            #expect(trunc["complete"] as? Bool == false)
            #expect((trunc["incompleteReasons"] as? [String])?.contains { $0.contains("top 500 of 900") } == true)
            #expect((trunc["limitations"] as? [String])?.contains { $0.contains("incomplete data") } == true)
            #expect((trunc["inferences"] as? [String])?.allSatisfy { $0.contains("withheld") } == true)

            let skipped = decode(try await hotspots(h, profileID("skipped"), callID: "s"))
            #expect(skipped["complete"] as? Bool == false)
            #expect((skipped["incompleteReasons"] as? [String])?.contains { $0.contains("7 samples") } == true)

            let empty = decode(try await hotspots(h, profileID("empty"), callID: "e"))
            #expect(empty["complete"] as? Bool == false)
            #expect((empty["incompleteReasons"] as? [String])?.contains { $0.contains("no usable samples") } == true)
            #expect(nestedList(empty, "rows").isEmpty)

            let whole = decode(try await hotspots(h, profileID("whole"), callID: "w"))
            #expect(whole["complete"] as? Bool == true)

            let listed = nestedList(decode(try await h.call("list_profiles", "{}")), "profiles")
            let byID = Dictionary(uniqueKeysWithValues: listed.map { ($0["profileID"] as? String ?? "", $0) })
            #expect(byID[profileID("trunc")]?["complete"] as? Bool == false)
            #expect(byID[profileID("whole")]?["complete"] as? Bool == true)
        }
    }

    @Test func observationsAreLabelledInferencesNeedVerifiedEvidenceAndNoSpeedupIsClaimed() async throws {
        try await withHarness { h in
            h.profileSource.attach("unknown", payload: try makePayload(hash: "unknown", entries: simpleEntries()))
            h.profileSource.attach("verified", payload: try makePayload(hash: "verified", entries: simpleEntries()), metadata: knownMetadata, mapping: .verified)

            let weak = decode(try await hotspots(h, profileID("unknown")))
            let weakObservations = weak["observations"] as? [String] ?? []
            #expect(!weakObservations.isEmpty)
            #expect(weakObservations.allSatisfy { $0.hasPrefix(ProfileEvidenceBuilder.observationLabel) })
            #expect((weak["inferences"] as? [String])?.allSatisfy { $0.hasPrefix(ProfileEvidenceBuilder.inferenceLabel) && $0.contains("withheld") } == true)
            #expect((weak["limitations"] as? [String])?.contains { $0.contains("workload, config, source hash, build") } == true)
            #expect((weak["limitations"] as? [String])?.contains { $0.contains("mapping is unverified") } == true)

            let strong = try await hotspots(h, profileID("verified"), callID: "strong")
            let strongData = decode(strong)
            let inferences = strongData["inferences"] as? [String] ?? []
            #expect(inferences.count == 1)
            #expect(inferences[0].hasPrefix(ProfileEvidenceBuilder.inferenceLabel))
            #expect(inferences[0].contains("candidate to investigate"))
            #expect(inferences[0].contains("timed benchmark"))

            for data in [weak, strongData] {
                let claim = try #require(data["speedupClaim"] as? String)
                #expect(claim.hasPrefix("none"))
                #expect(claim.contains("not a measured speedup"))
            }
            #expect(!strong.data.contains("% faster"))
            #expect(!strong.data.contains("will speed"))
        }
    }

    @Test func hotspotsPageWithCursorsAndRejectBadOnes() async throws {
        try await withHarness { h in
            h.profileSource.attach("p", payload: try makePayload(hash: "page", entries: simpleEntries()))
            let id = profileID("page")
            var functions: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let extra = ",\"limit\":1" + (cursor.map { ",\"cursor\":\"\($0)\"" } ?? "")
                let page = try await hotspots(h, id, extra: extra, callID: "page-\(pages)")
                functions += rows(page).compactMap { $0["function"] as? String }
                cursor = page.nextCursor
                pages += 1
            } while cursor != nil && pages < 10
            #expect(functions == ["pkg.Hot", "pkg.Cold", "pkg.Run"])
            #expect(pages == 3)

            let past = try await hotspots(h, id, extra: #","cursor":"99""#, callID: "past")
            #expect(rows(past).isEmpty)
            #expect(past.nextCursor == nil)
            let bad = try await hotspots(h, id, extra: #","cursor":"abc""#, callID: "bad")
            #expect(bad.errorCode == .invalidArguments)
        }
    }

    @Test func frameShowsCallersCalleesMappingAndOnlyVerifiedMappingGetsASourceRef() async throws {
        try await withHarness { h in
            h.profileSource.attach("weak", payload: try makePayload(hash: "weak", entries: simpleEntries()))
            h.profileSource.attach("strong", payload: try makePayload(hash: "strong", entries: simpleEntries()), metadata: knownMetadata, mapping: .verified)

            let weakID = profileID("weak")
            let weakRows = rows(try await hotspots(h, weakID))
            let hotID = try #require(weakRows.first { $0["function"] as? String == "pkg.Hot" }?["frameID"] as? String)
            let runID = try #require(weakRows.first { $0["function"] as? String == "pkg.Run" }?["frameID"] as? String)

            let weakFrame = try await h.call("profile_frame", "{\"profileID\":\"\(weakID)\",\"frameID\":\"\(hotID)\"}")
            #expect(weakFrame.status == .ok)
            let data = decode(weakFrame)
            #expect(data["function"] as? String == "pkg.Hot")
            #expect(data["unit"] as? String == "nanoseconds")
            #expect(data["denominator"] as? Int == 1000)
            #expect(data["flat"] as? Int == 600)
            #expect(data["flatShare"] as? Double == 0.6)
            #expect(data["cumShare"] as? Double == 0.7)
            #expect(data["isRecursive"] as? Bool == false)
            #expect((data["mappingNote"] as? String)?.contains("may not be the code that ran") == true)
            #expect((data["speedupClaim"] as? String)?.hasPrefix("none") == true)
            let callers = nestedList(data, "callers")
            #expect(callers.count == 1)
            #expect(callers[0]["function"] as? String == "pkg.Run")
            #expect(callers[0]["retained"] as? Bool == true)
            #expect(callers[0]["frameID"] as? String == runID)
            #expect(callers[0]["cum"] as? Int == 1000)
            let weakEvidence = try #require(await h.evidence.resolve(id: weakFrame.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(weakEvidence.sourceRefs.isEmpty)

            let strongID = profileID("strong")
            let strongRows = rows(try await hotspots(h, strongID, callID: "strong"))
            let strongHot = try #require(strongRows.first { $0["function"] as? String == "pkg.Hot" }?["frameID"] as? String)
            let strongFrame = try await h.call("profile_frame", "{\"profileID\":\"\(strongID)\",\"frameID\":\"\(strongHot)\"}", id: "frame-2")
            let strongEvidence = try #require(await h.evidence.resolve(id: strongFrame.evidenceIDs[0], workspaceID: h.workspaceID))
            #expect(strongEvidence.sourceRefs.map(\.path) == ["work.go"])
            #expect(decode(strongFrame)["mappingNote"] as? String == "The source mapping was verified against the current files.")
        }
    }

    @Test func unknownAndExpiredProfilesAndFramesAreReportedHonestly() async throws {
        try await withHarness { h in
            h.profileSource.attach("p", payload: try makePayload(hash: "life", entries: simpleEntries()))
            let id = profileID("life")
            let hot = try await hotspots(h, id)
            let frameID = try #require(rows(hot).first?["frameID"] as? String)

            #expect(try await hotspots(h, "P-unknown", callID: "u").errorCode == .notFound)
            let noFrame = try await h.call("profile_frame", "{\"profileID\":\"\(id)\",\"frameID\":\"F-none\"}")
            #expect(noFrame.errorCode == .notFound)
            let noProfile = try await h.call("profile_frame", "{\"profileID\":\"P-unknown\",\"frameID\":\"\(frameID)\"}", id: "f2")
            #expect(noProfile.errorCode == .notFound)

            await h.profiles.expire(id)
            let expiredHot = try await hotspots(h, id, callID: "expired")
            #expect(expiredHot.errorCode == .staleContext)
            let expiredFrame = try await h.call("profile_frame", "{\"profileID\":\"\(id)\",\"frameID\":\"\(frameID)\"}", id: "f3")
            #expect(expiredFrame.errorCode == .staleContext)
            let listed = nestedList(decode(try await h.call("list_profiles", "{}", id: "l")), "profiles")
            #expect(listed.first?["expired"] as? Bool == true)
            #expect(listed.first?["complete"] as? Bool == false)
        }
    }

    @Test func unsupportedAttachmentsAreCountedNotHidden() async throws {
        try await withHarness { h in
            h.profileSource.attach("goroutines", payload: try makePayload(mode: "goroutine", sampleType: "goroutine", unit: "count", hash: "gor", entries: simpleEntries()))
            let empty = try await h.call("list_profiles", "{}")
            #expect(decode(empty)["outcome"] as? String == "empty")
            #expect(decode(empty)["unsupportedAttachments"] as? Int == 1)

            h.profileSource.attach("cpu", payload: try makePayload(hash: "cpu-ok", entries: simpleEntries()))
            let mixed = try await h.call("list_profiles", "{}", id: "l2")
            #expect(decode(mixed)["unsupportedAttachments"] as? Int == 1)
            #expect(nestedList(decode(mixed), "profiles").count == 1)
        }
    }

    @Test func noProfileSourceMeansNoProfileTools() async throws {
        try await withHarness { h in
            var backends = h.backends
            backends.profiles = nil
            let registry = try h.registry(backends: backends)
            let names = registry.schemas.map(\.name)
            #expect(!names.contains("list_profiles") && !names.contains("profile_hotspots") && !names.contains("profile_frame"))
            let call = await registry.dispatch(ToolCall(id: "x", name: "profile_hotspots", argumentsJSON: "{\"profileID\":\"P\"}"))
            #expect(call.errorCode == .notFound)
        }
    }
}
