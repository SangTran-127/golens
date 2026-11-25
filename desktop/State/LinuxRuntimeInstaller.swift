import Foundation
import GoLensFoundation
import Observation

@MainActor
@Observable
final class LinuxRuntimeInstaller: NSObject {
    static let shared = LinuxRuntimeInstaller()
    static let trustedPublicKeys = ["FjhR/R4cPnOBEZvgU7gtKSAuqfGifkjkkvema7nSYCI="]
    static let agentProtocol = 1
    static let manifestFileName = "manifest.json"
    static let defaultManifestURL = "https://github.com/SangTran-127/golens/releases/latest/download/golens-linux-runtime.json"
    static let requiredFiles = ["vmlinuz", "rootfs.img", "golens-vm-agent", "goroot/bin/go", "NOTICES.txt"]

    enum Activity: Equatable {
        case none
        case checking
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case removing
    }

    struct Failure: Equatable {
        let title: String
        let message: String
    }

    private(set) var installed: LinuxRuntimeManifest?
    private(set) var available: LinuxRuntimeManifest?
    private(set) var availability: LinuxRuntimeAvailability?
    private(set) var activity: Activity = .none
    private(set) var failure: Failure?

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var signedManifestData: Data?
    @ObservationIgnored private var userCancelled = false

    let isSupported: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    var isInstalled: Bool { installed != nil }

    var isBusy: Bool { activity != .none }

    override private init() {
        super.init()
        installed = Self.readInstalledManifest()
    }

    private var runtimeDirectory: URL { LinuxRuntimeLocation.directory }

    private var downloadDirectory: URL { LinuxRuntimeLocation.downloadDirectory }

    private var resumeDataURL: URL {
        downloadDirectory.appendingPathComponent((available?.archive ?? "runtime") + ".resume")
    }

    private var manifestURL: URL? {
        let configured = ProcessInfo.processInfo.environment["GOLENS_RUNTIME_MANIFEST_URL"]
            ?? UserDefaults.standard.string(forKey: "GoLensRuntimeManifestURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "GoLensRuntimeManifestURL") as? String
            ?? Self.defaultManifestURL
        return URL(string: configured)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static func readInstalledManifest() -> LinuxRuntimeManifest? {
        let directory = LinuxRuntimeLocation.directory
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestFileName)),
              let manifest = LinuxRuntimeManifest.decode(data),
              requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { return nil }
        return manifest
    }

    func checkForRuntime() {
        guard isSupported, activity == .none, let manifestURL else { return }
        activity = .checking
        failure = nil
        Task {
            do {
                let manifestData = try await Self.fetch(manifestURL)
                let signature = try await Self.fetch(manifestURL.appendingPathExtension("sig"))
                guard LinuxRuntimeVerification.isSignatureValid(manifest: manifestData, signatureBase64: String(decoding: signature, as: UTF8.self), publicKeysBase64: Self.trustedPublicKeys),
                      let manifest = LinuxRuntimeManifest.decode(manifestData) else {
                    throw InstallError.untrustedManifest
                }
                guard manifest.arch == "arm64" else { throw InstallError.untrustedManifest }
                signedManifestData = manifestData
                available = manifest
                availability = LinuxRuntimeAvailability.resolve(installed: installed, available: manifest, appVersion: appVersion, agentProtocol: Self.agentProtocol)
                activity = .none
            } catch {
                activity = .none
                failure = Failure(title: "Couldn’t Check for the Linux Sandbox", message: Self.describe(error))
            }
        }
    }

    func download() {
        guard isSupported, activity == .none || activity == .checking,
              let manifest = available, let manifestURL else { return }
        failure = nil
        userCancelled = false
        let archiveURL = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.archive)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let resumeData = try? Data(contentsOf: resumeDataURL)
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: archiveURL)
        try? FileManager.default.removeItem(at: resumeDataURL)
        self.task = task
        activity = .downloading(received: 0, total: manifest.archiveSize)
        task.resume()
    }

    func cancelDownload() {
        guard case .downloading = activity, let task else { return }
        userCancelled = true
        task.cancel { [weak self] data in
            Task { @MainActor in self?.storeResumeData(data) }
        }
        activity = .none
    }

    func remove() {
        guard activity == .none else { return }
        activity = .removing
        failure = nil
        Task {
            await SandboxVMManager.shared.stop()
            LinuxSandboxProjects.shared.runtimeRemoved()
            let directory = runtimeDirectory
            let snapshot = SandboxVMManager.shared.snapshotFileURL()
            let removed = await Task.detached(priority: .userInitiated) { () -> Bool in
                try? FileManager.default.removeItem(at: snapshot)
                do {
                    if FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.removeItem(at: directory)
                    }
                    return true
                } catch {
                    return false
                }
            }.value
            installed = Self.readInstalledManifest()
            if let available {
                availability = LinuxRuntimeAvailability.resolve(installed: installed, available: available, appVersion: appVersion, agentProtocol: Self.agentProtocol)
            }
            activity = .none
            if !removed {
                failure = Failure(title: "Couldn’t Remove the Linux Sandbox", message: "GoLens couldn’t delete \(directory.path). Quit GoLens, delete the folder in Finder, and open GoLens again.")
            }
            SandboxVMManager.shared.refreshLinuxGoVersion()
            SandboxVMManager.shared.refreshLinuxKernelVersion()
        }
    }

    func dismissFailure() {
        failure = nil
    }

    private func storeResumeData(_ data: Data?) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        try? data.write(to: resumeDataURL, options: .atomic)
    }

    private func downloadFinished(at file: URL) {
        guard let manifest = available, let manifestData = signedManifestData else { return }
        activity = .verifying
        let directory = runtimeDirectory
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.verify(file, against: manifest)
                }.value
                activity = .installing
                let staging = try await Task.detached(priority: .userInitiated) {
                    try Self.unpack(file, manifestData: manifestData, next: directory)
                }.value
                await SandboxVMManager.shared.stop()
                let snapshot = SandboxVMManager.shared.snapshotFileURL()
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: snapshot)
                    try Self.swap(staging, into: directory)
                }.value
                try? FileManager.default.removeItem(at: file)
                installed = Self.readInstalledManifest()
                availability = installed == nil ? availability : .upToDate
                activity = .none
                SandboxVMManager.shared.refreshLinuxGoVersion()
                SandboxVMManager.shared.refreshLinuxKernelVersion()
                LinuxSandboxProjects.shared.applyExecutionMode()
            } catch {
                try? FileManager.default.removeItem(at: file)
                activity = .none
                failure = Failure(title: "Couldn’t Install the Linux Sandbox", message: Self.describe(error))
            }
        }
    }

    private func downloadFailed(_ error: Error) {
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        storeResumeData(resumeData)
        if userCancelled {
            userCancelled = false
            return
        }
        activity = .none
        let detail = (error as NSError).localizedDescription
        failure = Failure(
            title: "The Download Stopped",
            message: resumeData == nil
                ? "\(detail) Retry starts the download again."
                : "\(detail) Retry continues where it stopped."
        )
    }

    enum InstallError: Error {
        case untrustedManifest
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch
        case unpackFailed(String)
        case incomplete(String)
        case http(Int)
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case InstallError.untrustedManifest:
            return "The runtime description isn’t signed by GoLens, so it was not used. Check your network or try again later."
        case let InstallError.sizeMismatch(expected, actual):
            return "The download is \(UserMessage.byteCount(actual)) but should be \(UserMessage.byteCount(expected)), so GoLens deleted it. Retry downloads it again."
        case InstallError.checksumMismatch:
            return "The download doesn’t match its signed checksum, so GoLens deleted it. Retry downloads it again."
        case let InstallError.unpackFailed(detail):
            return "GoLens couldn’t unpack the runtime: \(detail)"
        case let InstallError.incomplete(file):
            return "The runtime is missing \(file). Retry downloads it again."
        case let InstallError.http(status):
            return "The download server answered with HTTP \(status). Try again later."
        default:
            return (error as NSError).localizedDescription
        }
    }

    nonisolated private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.http(http.statusCode)
        }
        return data
    }

    nonisolated private static func verify(_ file: URL, against manifest: LinuxRuntimeManifest) throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard size == manifest.archiveSize else { throw InstallError.sizeMismatch(expected: manifest.archiveSize, actual: size) }
        guard LinuxRuntimeVerification.sha256Hex(ofFileAt: file)?.lowercased() == manifest.sha256.lowercased() else {
            throw InstallError.checksumMismatch
        }
    }

    nonisolated private static func unpack(_ archive: URL, manifestData: Data, next directory: URL) throws -> URL {
        let staging = directory.deletingLastPathComponent().appendingPathComponent("VMRuntime.staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", staging.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw InstallError.unpackFailed(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for file in requiredFiles where !FileManager.default.fileExists(atPath: staging.appendingPathComponent(file).path) {
            try? FileManager.default.removeItem(at: staging)
            throw InstallError.incomplete(file)
        }
        try manifestData.write(to: staging.appendingPathComponent(manifestFileName), options: .atomic)
        return staging
    }

    nonisolated private static func swap(_ staging: URL, into directory: URL) throws {
        let fileManager = FileManager.default
        let previous = directory.deletingLastPathComponent().appendingPathComponent("VMRuntime.previous", isDirectory: true)
        try? fileManager.removeItem(at: previous)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.moveItem(at: directory, to: previous)
        }
        do {
            try fileManager.moveItem(at: staging, to: directory)
        } catch {
            if fileManager.fileExists(atPath: previous.path) { try? fileManager.moveItem(at: previous, to: directory) }
            throw error
        }
        try? fileManager.removeItem(at: previous)
    }
}

extension LinuxRuntimeInstaller: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard case let .downloading(_, total) = self.activity else { return }
            self.activity = .downloading(received: totalBytesWritten, total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        Task { @MainActor in
            guard case let .downloading(_, total) = self.activity else { return }
            self.activity = .downloading(received: fileOffset, total: expectedTotalBytes > 0 ? expectedTotalBytes : total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in self.downloadFailed(InstallError.http(http.statusCode)) }
            return
        }
        let directory = LinuxRuntimeLocation.downloadDirectory
        let kept = directory.appendingPathComponent("runtime.tar.gz")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: kept)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            Task { @MainActor in self.downloadFinished(at: kept) }
        } catch {
            Task { @MainActor in self.downloadFailed(error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let error else { return }
        Task { @MainActor in self.downloadFailed(error) }
    }
}
