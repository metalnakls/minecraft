import CryptoKit
import Foundation
import ZIPFoundation

/// Checks only installed MCUI copies, before Java opens the instance's mod JARs.
actor MCUIUpdater {
    static let shared = MCUIUpdater()
    typealias Fetch = @Sendable (URL) async throws -> Data

    enum Outcome: Equatable, Sendable {
        case disabled, absent, unchanged
        case updated(String), kept(String)

        var message: String {
            switch self {
            case .disabled: "Automatic MCUI updates are off."
            case .absent: "MCUI is not installed in this instance."
            case .unchanged: "No newer compatible MCUI release found."
            case let .updated(version): "Updated MCUI to \(version)."
            case let .kept(reason): "Kept installed MCUI: \(reason)"
            }
        }
    }

    private struct Release: Decodable {
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        let published_at: String?
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int
        let digest: String?
        let browser_download_url: URL
    }

    private enum Requirement: Decodable {
        case one(String), any([String])
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { self = .one(string) }
            else { self = .any(try value.decode([String].self)) }
        }
        func matches(_ version: String) -> Bool {
            switch self {
            case let .one(value): MCUIUpdater.matches(version, requirement: value)
            case let .any(values): values.contains { MCUIUpdater.matches(version, requirement: $0) }
            }
        }
    }

    private struct Manifest: Decodable {
        let id: String
        let version: String
        let depends: [String: Requirement]?
    }

    private enum UpdateError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case let .invalid(message): return message }
        }
    }

    private let fetch: Fetch
    private var inFlight: [URL: Task<Outcome, Never>] = [:]

    init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.download
    }

    func check(profile: URL, minecraft: String, loader: String, java: Int, enabled: Bool = true) async -> Outcome {
        guard enabled else { return .disabled }
        let profile = profile.standardizedFileURL
        if let pending = inFlight[profile] { return await pending.value }
        let pending = Task {
            do { return try await self.perform(profile: profile, minecraft: minecraft, loader: loader, java: java) }
            catch { return Outcome.kept(error.localizedDescription) }
        }
        inFlight[profile] = pending
        let result = await pending.value
        inFlight[profile] = nil
        return result
    }

    private func perform(profile: URL, minecraft: String, loader: String, java: Int) async throws -> Outcome {
        let manager = FileManager.default
        let mods = profile.appendingPathComponent("mods", isDirectory: true)
        guard manager.fileExists(atPath: mods.path) else { return .absent }
        var installed: [(URL, Manifest)] = []
        var versions = ["minecraft": minecraft, "fabricloader": loader, "java": String(java)]
        for url in try manager.contentsOfDirectory(at: mods, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where url.pathExtension == "jar" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let manifest = try? Self.manifest(Archive(url: url, accessMode: .read)) else { continue }
            versions[manifest.id] = manifest.version
            if manifest.id == "cleanmenu" { installed.append((url, manifest)) }
        }
        guard !installed.isEmpty else { return .absent }
        guard installed.count == 1 else { throw UpdateError.invalid("multiple MCUI JARs are installed") }
        let (destination, current) = installed[0]
        let original = try Data(contentsOf: destination)
        let originalHash = Self.hash(original)
        let listURL = URL(string: "https://api.github.com/repos/metalnakls/MCUI/releases?per_page=100")!
        let list = try await fetch(listURL)
        guard list.count <= 4_000_000 else { throw UpdateError.invalid("release metadata is too large") }
        let releases = try JSONDecoder().decode([Release].self, from: list)
            .filter { !$0.draft && !$0.prerelease }
            .sorted { ($0.published_at ?? "") > ($1.published_at ?? "") }
        let deadline = Date().addingTimeInterval(20)
        for release in releases {
            guard Date() < deadline else { throw UpdateError.invalid("update check timed out") }
            guard let asset = release.assets.first(where: { $0.name.hasPrefix("mcui-") && $0.name.hasSuffix(".jar") }),
                  asset.browser_download_url.absoluteString.hasPrefix("https://github.com/metalnakls/MCUI/releases/download/"),
                  asset.size > 0, asset.size <= 20_000_000,
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { continue }
            let expected = String(digest.dropFirst(7)).lowercased()
            guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else { continue }
            if expected == originalHash { return .unchanged }
            let data = try await fetch(asset.browser_download_url)
            guard data.count == asset.size, Self.hash(data) == expected else {
                throw UpdateError.invalid("download checksum does not match GitHub")
            }
            let candidate = try Self.manifest(Archive(data: data, accessMode: .read))
            guard candidate.id == "cleanmenu",
                  let comparison = Self.compare(candidate.version, current.version), comparison > 0,
                  let dependencies = candidate.depends,
                  dependencies["minecraft"] != nil,
                  dependencies.allSatisfy({ id, requirement in versions[id].map(requirement.matches) ?? false }) else { continue }
            try Task.checkCancellation()
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Self.hash(try Data(contentsOf: destination)) == originalHash else {
                throw UpdateError.invalid("installed file changed while checking")
            }
            let backups = profile.appendingPathComponent(".mcui-backups", isDirectory: true)
            try manager.createDirectory(at: backups, withIntermediateDirectories: true)
            guard try backups.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw UpdateError.invalid("backup directory is a symbolic link")
            }
            let backup = backups.appendingPathComponent(originalHash + ".jar")
            if !manager.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
            guard Self.hash(try Data(contentsOf: backup)) == originalHash else {
                throw UpdateError.invalid("backup verification failed")
            }
            // Atomic replacement retains the filename, so there is never a duplicate mod ID.
            try data.write(to: destination, options: .atomic)
            return .updated(candidate.version)
        }
        return .unchanged
    }

    private static func manifest(_ archive: Archive) throws -> Manifest {
        guard let entry = archive["fabric.mod.json"], entry.uncompressedSize <= 65_536 else {
            throw UpdateError.invalid("missing or oversized Fabric manifest")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Unsupported Fabric predicates are rejected, rather than assuming compatibility.
    static func matches(_ version: String, requirement: String) -> Bool {
        let parts = requirement.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            if part == "*" { return true }
            if part.hasSuffix(".x") || part.hasSuffix(".*") {
                let prefix = String(part.dropLast(2))
                return version == prefix || version.hasPrefix(prefix + ".")
            }
            let op = [">=", "<=", ">", "<", "="].first(where: part.hasPrefix) ?? ""
            let requested = String(part.dropFirst(op.count))
            guard let comparison = compare(version, requested) else { return false }
            switch op {
            case ">=": return comparison >= 0
            case "<=": return comparison <= 0
            case ">": return comparison > 0
            case "<": return comparison < 0
            default: return comparison == 0
            }
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Int? {
        func numbers(_ value: String) -> [Int]? {
            let base = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let parts = base.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
            let values = parts.compactMap { Int($0) }
            return values.count == parts.count ? values : nil
        }
        guard let left = numbers(lhs), let right = numbers(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func download(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("metalnakls-minecraft/1.3.6", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateError.invalid("GitHub is unavailable or rate-limited")
        }
        return data
    }
}
