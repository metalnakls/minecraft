import Foundation
import Testing
@testable import SharedSetupCore

struct SharedLaunchSettingsTests {
@Test func sharedSettingsTransferAndBackup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = SharedLaunchSettings(schema: 1, jvmArguments: "-XX:+UseZGC -XX:+OptimizeStringConcat", xms: 1024, xmx: 8192)
    let file = root.appendingPathComponent(SharedLaunchSettings.filename)
    try JSONEncoder().encode(settings).write(to: file)
    let pending = try #require(try SharedLaunchSettings.pending(in: root))
    #expect(pending.settings == settings)
    let old = SharedLaunchSettings(schema: 1, jvmArguments: "-XX:+UseG1GC", xms: 512, xmx: 4096)
    try old.backup(in: root)
    let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".shared-launch-settings-backups"), includingPropertiesForKeys: nil)
    #expect(try JSONDecoder().decode(SharedLaunchSettings.self, from: Data(contentsOf: backups[0])) == old)
    try SharedLaunchSettings.markApplied(pending, in: root)
    #expect(try SharedLaunchSettings.pending(in: root) == nil)
    try FileManager.default.removeItem(at: root.appendingPathComponent(SharedLaunchSettings.markerName))
    #expect(try SharedLaunchSettings.pending(in: root) != nil)
    #expect(SharedLaunchSettings.removingCollectorOptions(from: ["-XX:+UseG1GC", "-XX:-UseZGC", "-Xss1M", "Main"]) == ["-Xss1M", "Main"])
}

@Test func rejectsUnsharedLaunchArguments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let value = SharedLaunchSettings(schema: 1, jvmArguments: "-XX:+UseZGC -javaagent:/some/local/file.jar", xms: 1024, xmx: 8192)
    try JSONEncoder().encode(value).write(to: root.appendingPathComponent(SharedLaunchSettings.filename))
    #expect(throws: (any Error).self) { try SharedLaunchSettings.pending(in: root) }
}

}
