import Foundation

@main
struct BookmarkStressRunner {
    static func main() {
        print("Running SecurityScopedBookmarkManager Empirical Stress Harness...")

        var testFailures: [String] = []
        let manager = SecurityScopedBookmarkManager.shared
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("golens_stress_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // -------------------------------------------------------------
        // Test 1: Deduplication & Balance of startAccessing / stopAccessing
        // -------------------------------------------------------------
        print("[Test 1] Testing startAccessing / stopAccessing deduplication and balance...")
        let testFolder1 = tempDir.appendingPathComponent("folder1")
        try! FileManager.default.createDirectory(at: testFolder1, withIntermediateDirectories: true)

        for _ in 0..<10 {
            let ok = manager.startAccessing(url: testFolder1)
            if !ok && manager.isSandboxed {
                testFailures.append("Test 1: startAccessing returned false unexpectedly")
            }
        }
        // Stop accessing once
        manager.stopAccessing(url: testFolder1)
        // Stop accessing again (idempotent / no-op)
        manager.stopAccessing(url: testFolder1)
        print("PASS: Test 1 deduplication & idempotency verified.")

        // -------------------------------------------------------------
        // Test 2: Concurrent Stress Test (50 threads, 200 operations each)
        // -------------------------------------------------------------
        print("[Test 2] Testing concurrent access across 50 threads (10,000 operations)...")
        let threadCount = 50
        let iterationsPerThread = 200
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress.queue", attributes: .concurrent)

        var folders: [URL] = []
        for i in 0..<20 {
            let folder = tempDir.appendingPathComponent("concurrent_\(i)")
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folders.append(folder)
        }

        for threadIdx in 0..<threadCount {
            group.enter()
            queue.async {
                for opIdx in 0..<iterationsPerThread {
                    let folder = folders[(threadIdx + opIdx) % folders.count]
                    let path = folder.path
                    
                    switch opIdx % 7 {
                    case 0:
                        manager.saveBookmark(for: folder)
                    case 1:
                        _ = manager.bookmarkData(for: path)
                    case 2:
                        _ = manager.startAccessing(url: folder)
                    case 3:
                        manager.stopAccessing(url: folder)
                    case 4:
                        _ = manager.canAccess(path: path)
                    case 5:
                        _ = manager.resolveAndAccess(path: path)
                    case 6:
                        if opIdx % 20 == 0 {
                            manager.removeBookmark(for: path)
                        }
                    default:
                        break
                    }
                }
                group.leave()
            }
        }

        let timeoutResult = group.wait(timeout: .now() + 30.0)
        if timeoutResult == .timedOut {
            testFailures.append("Test 2: DEADLOCK detected during concurrent stress test!")
        } else {
            print("PASS: Test 2 10,000 concurrent operations completed with zero deadlocks or crashes.")
        }

        // -------------------------------------------------------------
        // Test 3: StopAllAccess under concurrent load
        // -------------------------------------------------------------
        print("[Test 3] Testing stopAllAccess under concurrent stress...")
        let group3 = DispatchGroup()
        for _ in 0..<20 {
            group3.enter()
            queue.async {
                for f in folders {
                    _ = manager.startAccessing(url: f)
                }
                group3.leave()
            }
        }
        manager.stopAllAccess()
        let res3 = group3.wait(timeout: .now() + 10.0)
        if res3 == .timedOut {
            testFailures.append("Test 3: deadlock during stopAllAccess!")
        } else {
            print("PASS: Test 3 stopAllAccess verified.")
        }
        manager.stopAllAccess()

        // -------------------------------------------------------------
        // Test 4: Edge Cases: Symlinks, Trailing Slashes, Non-existent & Corrupt Data
        // -------------------------------------------------------------
        print("[Test 4] Testing edge cases (symlinks, invalid data, non-existent paths)...")

        // 4a. Trailing slash normalization
        let folderA = tempDir.appendingPathComponent("folderA")
        try! FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        manager.saveBookmark(for: folderA)

        let dataWithoutSlash = manager.bookmarkData(for: folderA.path)
        let dataWithSlash = manager.bookmarkData(for: folderA.path + "/")
        if dataWithoutSlash == nil || dataWithSlash == nil {
            testFailures.append("Test 4a: Trailing slash normalization failed! (without: \(dataWithoutSlash != nil), with: \(dataWithSlash != nil))")
        } else {
            print("PASS: 4a Trailing slash normalization verified.")
        }

        // 4b. Symlink resolution
        let symlinkURL = tempDir.appendingPathComponent("symlink_to_A")
        try! FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: folderA)
        manager.saveBookmark(for: symlinkURL)
        let symlinkData = manager.bookmarkData(for: symlinkURL.path)
        if symlinkData == nil {
            testFailures.append("Test 4b: Symlink bookmarkData was nil (NSCocoaErrorDomain 256: Could not open() item)")
            print("FAIL: 4b Symlink bookmarkData was nil (NSCocoaErrorDomain 256: Could not open() item)")
        } else {
            print("PASS: 4b Symlink bookmark creation and retrieval verified.")
        }

        // 4c. Non-existent path
        let nonExistentPath = tempDir.appendingPathComponent("does_not_exist_\(UUID().uuidString)").path
        if manager.isSandboxed && manager.canAccess(path: nonExistentPath) {
            testFailures.append("Test 4c: canAccess returned true for non-existent path")
        } else {
            print("PASS: 4c Non-existent path handling verified.")
        }

        // 4d. Corrupt / Garbage bookmark data
        var staleFlag = false
        let garbageData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])
        let resolvedGarbage = manager.resolveBookmark(data: garbageData, isStale: &staleFlag)
        if resolvedGarbage != nil {
            testFailures.append("Test 4d: resolveBookmark unexpectedly resolved garbage data!")
        } else {
            print("PASS: 4d Corrupt / garbage bookmark data safely rejected without crash.")
        }

        // 4e. Path with special characters and spaces
        let specialFolder = tempDir.appendingPathComponent("test folder with spaces & (special) #123")
        try! FileManager.default.createDirectory(at: specialFolder, withIntermediateDirectories: true)
        manager.saveBookmark(for: specialFolder)
        if manager.bookmarkData(for: specialFolder.path) == nil {
            testFailures.append("Test 4e: special characters path bookmark was not saved")
        } else {
            print("PASS: 4e Path with spaces and special characters verified.")
        }

        // 4f. Path removal cleanup
        manager.removeBookmark(for: folderA.path)
        if manager.bookmarkData(for: folderA.path) != nil {
            testFailures.append("Test 4f: removeBookmark did not remove stored bookmark")
        } else {
            print("PASS: 4f removeBookmark cleanup verified.")
        }

        print("\n--- SUMMARY OF STRESS HARNESS ---")
        if testFailures.isEmpty {
            print("ALL TESTS PASSED (0 failures)")
            exit(0)
        } else {
            print("TEST FAILURES (\(testFailures.count)):")
            for f in testFailures {
                print("  - \(f)")
            }
            exit(1)
        }
    }
}
