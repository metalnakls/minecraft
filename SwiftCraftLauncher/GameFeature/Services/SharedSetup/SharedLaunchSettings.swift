import CryptoKit
import Foundation

/// The portable, explicitly selected launch settings shipped with the shared setup.
struct SharedLaunchSettings: Codable, Equatable, Sendable {
    let schema: Int
    let jvmArguments: String
    let xms: Int
    let xmx: Int

    static let filename = "shared-launch-settings.json"
    static let markerName = ".shared-launch-settings.applied"
    static let allowedArguments: Set<String> = [
        "-XX:+UseZGC", "-XX:+OptimizeStringConcat", "-XX:+OmitStackTraceInFastThrow",
        "-XX:+UseCompressedOops", "-XX:+UseCompressedClassPointers", "-XX:+UseCompactObjectHeaders"
    ]

    struct Pending: Sendable {
        let settings: SharedLaunchSettings
        let digest: String
    }

    static func pending(in profile: URL) throws -> Pending? {
        let source = profile.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let data = try Data(contentsOf: source)
        let settings = try JSONDecoder().decode(Self.self, from: data)
        let arguments = settings.jvmArguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard settings.schema == 1, settings.xms > 0, settings.xmx >= settings.xms,
              arguments.contains("-XX:+UseZGC"), arguments.allSatisfy(allowedArguments.contains) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let marker = profile.appendingPathComponent(markerName)
        guard (try? String(contentsOf: marker, encoding: .utf8)) != digest else { return nil }
        return Pending(settings: settings, digest: digest)
    }

    func backup(in profile: URL) throws {
        let folder = profile.appendingPathComponent(".shared-launch-settings-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let path = folder.appendingPathComponent("\(digest).json")
        if !FileManager.default.fileExists(atPath: path.path) { try data.write(to: path, options: .atomic) }
        guard try Data(contentsOf: path) == data else { throw CocoaError(.fileWriteUnknown) }
    }

    static func markApplied(_ pending: Pending, in profile: URL) throws {
        try Data(pending.digest.utf8).write(to: profile.appendingPathComponent(markerName), options: .atomic)
    }

    static func removingCollectorOptions(from command: [String]) -> [String] {
        let collectors = ["G1", "Z", "Shenandoah", "Parallel", "Serial", "Epsilon"]
        let options = Set(collectors.flatMap { ["-XX:+Use\($0)GC", "-XX:-Use\($0)GC"] })
        return command.filter { !options.contains($0) }
    }
}
