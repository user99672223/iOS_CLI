import Foundation
import CryptoKit
import ZIPFoundation
import os

/// Downloads and installs the Windows tools into the prefix:
/// - Claude Code (win32-arm64 claude.exe) from Anthropic's release bucket,
///   verified against the release manifest's SHA-256. Never bundled.
/// - Git for Windows ARM64 (MinGit busybox variant): native ARM64 git and
///   busybox-w32 shell; verified against the pinned SHA-256.
@MainActor
final class ToolInstaller: ObservableObject {
    static let shared = ToolInstaller()

    struct Progress: Equatable {
        var title: String
        var fraction: Double?
        var detail: String = ""
    }

    @Published private(set) var progress: Progress?
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: "cli.app", category: "installer")

    static let releaseBase = URL(string: "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases")!
    static let platform = "win32-arm64"

    static let gitVersion = "2.56.1"
    static let gitURL = URL(string: "https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/MinGit-2.56.1-busybox-arm64.zip")!
    static let gitSHA256 = "42396e389d1b38861fea05edc716b2389e071008c44dd62a53ba05bb85f65494"

    // MARK: state

    static var claudeVersionFile: URL { AppPaths.claudeExe.deletingLastPathComponent().appendingPathComponent("VERSION") }
    static var installedClaudeVersion: String? {
        guard FileManager.default.fileExists(atPath: AppPaths.claudeExe.path) else { return nil }
        return (try? String(contentsOf: claudeVersionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var gitMarker: URL { AppPaths.gitDir.appendingPathComponent(".harbor-version") }
    static var installedGitVersion: String? {
        (try? String(contentsOf: gitMarker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var isInstalled: Bool { installedClaudeVersion != nil && installedGitVersion != nil }

    // MARK: Claude Code

    struct Release { var version: String; var checksum: String; var size: Int64 }

    static func fetchRelease(channel: String = "latest") async throws -> Release {
        let (vData, _) = try await URLSession.shared.data(from: releaseBase.appendingPathComponent(channel))
        let version = String(decoding: vData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) != nil else {
            throw InstallError.badResponse("version \(version.prefix(40))")
        }
        let (mData, _) = try await URLSession.shared.data(from: releaseBase.appendingPathComponent("\(version)/manifest.json"))
        guard let m = try JSONSerialization.jsonObject(with: mData) as? [String: Any],
              let platforms = m["platforms"] as? [String: Any],
              let p = platforms[platform] as? [String: Any],
              let checksum = p["checksum"] as? String else {
            throw InstallError.badResponse("manifest has no \(platform) entry")
        }
        let size = (p["size"] as? NSNumber)?.int64Value ?? 0
        return Release(version: version, checksum: checksum.lowercased(), size: size)
    }

    func installClaude(channel: String = "latest") async throws {
        progress = Progress(title: "Checking Claude Code release", fraction: nil)
        let r = try await Self.fetchRelease(channel: channel)
        if Self.installedClaudeVersion == r.version { progress = nil; return }
        let url = Self.releaseBase.appendingPathComponent("\(r.version)/\(Self.platform)/claude.exe")
        let tmp = try await download(url, title: "Downloading Claude Code \(r.version)", expectedSize: r.size)
        defer { try? FileManager.default.removeItem(at: tmp) }
        progress = Progress(title: "Verifying Claude Code", fraction: nil)
        let digest = try await Self.sha256(of: tmp)
        guard digest == r.checksum else { throw InstallError.checksum("claude.exe") }
        let dir = AppPaths.claudeExe.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: AppPaths.claudeExe)
        try FileManager.default.moveItem(at: tmp, to: AppPaths.claudeExe)
        try r.version.write(to: Self.claudeVersionFile, atomically: true, encoding: .utf8)
        excludeFromBackup(dir)
        log.log("installed Claude Code \(r.version, privacy: .public)")
        progress = nil
    }

    // MARK: Git

    func installGit() async throws {
        if Self.installedGitVersion == Self.gitVersion { return }
        let tmp = try await download(Self.gitURL, title: "Downloading Git \(Self.gitVersion)", expectedSize: 30_000_000)
        defer { try? FileManager.default.removeItem(at: tmp) }
        progress = Progress(title: "Verifying Git", fraction: nil)
        guard try await Self.sha256(of: tmp) == Self.gitSHA256 else { throw InstallError.checksum("MinGit") }
        progress = Progress(title: "Unpacking Git", fraction: nil)
        let dest = AppPaths.gitDir
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.unzipItem(at: tmp, to: dest)
        }.value
        // busybox-w32 picks the applet from argv[0]: bash.exe -> its bash (ash).
        let bin = dest.appendingPathComponent("clangarm64/bin")
        for name in ["bash.exe", "sh.exe"] {
            let link = bin.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "busybox.exe")
        }
        try Self.gitVersion.write(to: Self.gitMarker, atomically: true, encoding: .utf8)
        excludeFromBackup(dest)
        progress = nil
    }

    // MARK: configuration in the prefix

    /// Claude Code settings and git configuration in %USERPROFILE%.
    static func writeConfiguration() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.claudeConfig, withIntermediateDirectories: true)
        try fm.createDirectory(at: AppPaths.workspace, withIntermediateDirectories: true)
        let settingsURL = AppPaths.claudeConfig.appendingPathComponent("settings.json")
        var settings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) as? [String: Any] ?? [:]
        var perms = settings["permissions"] as? [String: Any] ?? [:]
        perms["defaultMode"] = "bypassPermissions"
        settings["permissions"] = perms
        settings["autoUpdates"] = false
        settings["includeCoAuthoredBy"] = settings["includeCoAuthoredBy"] ?? true
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)

        let git = AppPaths.windowsPath(AppPaths.gitDir).replacingOccurrences(of: "\\", with: "/")
        let gitconfig = """
        [http]
        \tsslBackend = openssl
        \tsslCAInfo = \(git)/clangarm64/etc/ssl/certs/ca-bundle.crt
        [core]
        \tautocrlf = false
        \tsymlinks = false
        \tfscache = false
        [credential]
        \thelper =
        [safe]
        \tdirectory = *
        [init]
        \tdefaultBranch = main

        """
        let gcURL = AppPaths.userProfile.appendingPathComponent(".gitconfig")
        try fm.createDirectory(at: AppPaths.userProfile, withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: gcURL, encoding: .utf8), existing.contains("[user]") {
            // Keep the user's identity if they set one.
            let user = existing.components(separatedBy: "[user]").last.map { "[user]" + $0 } ?? ""
            try (gitconfig + user).write(to: gcURL, atomically: true, encoding: .utf8)
        } else {
            try gitconfig.write(to: gcURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: helpers

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    private func download(_ url: URL, title: String, expectedSize: Int64) async throws -> URL {
        progress = Progress(title: title, fraction: 0)
        let delegate = DownloadDelegate { [weak self] written, total in
            Task { @MainActor in
                let t = total > 0 ? total : expectedSize
                self?.progress = Progress(title: title, fraction: t > 0 ? min(1, Double(written) / Double(t)) : nil,
                                          detail: ByteCountFormatter.string(fromByteCount: written, countStyle: .file))
            }
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.badResponse("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    enum InstallError: Error, CustomStringConvertible {
        case badResponse(String), checksum(String)
        var description: String {
            switch self {
            case .badResponse(let s): return "Unexpected response from the download server (\(s))"
            case .checksum(let s): return "The download of \(s) failed verification (SHA-256 mismatch)"
            }
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Int64, Int64) -> Void
    private var last = Date.distantPast
    init(onProgress: @escaping (Int64, Int64) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard Date().timeIntervalSince(last) > 0.2 else { return }
        last = Date()
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
