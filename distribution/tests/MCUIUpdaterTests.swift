import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import MCUIUpdateCore

private let assetURL = URL(string: "https://github.com/metalnakls/MCUI/releases/download/v0.2.0/mcui-0.2.0.jar")!

private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func jar(version: String, minecraft: String = "26.3", id: String = "cleanmenu", breaks: [String: String] = [:]) throws -> Data {
    let manifest: [String: Any] = ["id": id, "version": version, "breaks": breaks, "depends": [
        "minecraft": minecraft, "fabricloader": ">=0.19.5", "java": ">=25", "modmenu": "*"
    ]]
    let data = try JSONSerialization.data(withJSONObject: manifest)
    let archive = try Archive(data: Data(), accessMode: .create)
    try archive.addEntry(with: "fabric.mod.json", type: .file, uncompressedSize: Int64(data.count)) { offset, size in
        data.subdata(in: Int(offset)..<(Int(offset) + size))
    }
    return try #require(archive.data)
}

private func releases(_ data: Data, digest: String? = nil, prerelease: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: [[
        "draft": false, "prerelease": prerelease, "published_at": "2026-10-31T12:00:00Z",
        "assets": [["name": "mcui-0.2.0.jar", "size": data.count,
                    "digest": "sha256:" + (digest ?? hash(data)), "browser_download_url": assetURL.absoluteString]]
    ]])
}

private struct Fixture {
    let root: URL
    let installed: URL
    let original: Data

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mods = root.appendingPathComponent("mods")
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        installed = mods.appendingPathComponent("clean-menu-0.1.0.jar")
        original = try jar(version: "0.1.0")
        try original.write(to: installed)
        try jar(version: "21.0.0", id: "modmenu").write(to: mods.appendingPathComponent("modmenu.jar"))
    }

    func check(_ updater: MCUIUpdater, enabled: Bool = true) async -> MCUIUpdater.Outcome {
        await updater.check(profile: root, minecraft: "26.3", loader: "0.19.5", java: 25, enabled: enabled)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor Transport {
    let metadata: Data
    let payload: Data
    var calls = 0
    init(metadata: Data, payload: Data) { self.metadata = metadata; self.payload = payload }
    func get(_ url: URL) async throws -> Data {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        return url.host == "api.github.com" ? metadata : payload
    }
}

@Test func installsBeforeLaunchAndKeepsBackupSettingsAndSaves() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let settings = fixture.root.appendingPathComponent("options.txt")
    try Data("personal settings".utf8).write(to: settings)
    let saves = fixture.root.appendingPathComponent("saves")
    try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
    try Data("world".utf8).write(to: saves.appendingPathComponent("level.dat"))
    let payload = try jar(version: "0.2.0")
    let transport = Transport(metadata: try releases(payload), payload: payload)
    let updater = MCUIUpdater(fetch: { try await transport.get($0) })
    #expect(await fixture.check(updater) == .updated("0.2.0"))
    #expect(try Data(contentsOf: fixture.installed) == payload)
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".mcui-backups/" + hash(fixture.original) + ".jar")) == fixture.original)
    #expect(try String(contentsOf: settings, encoding: .utf8) == "personal settings")
    #expect(try String(contentsOf: saves.appendingPathComponent("level.dat"), encoding: .utf8) == "world")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("mods").path).count == 2)
}

@Test func disabledDoesNotAccessNetwork() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let transport = Transport(metadata: Data(), payload: Data())
    let updater = MCUIUpdater(fetch: { try await transport.get($0) })
    #expect(await fixture.check(updater, enabled: false) == .disabled)
    #expect(await transport.calls == 0)
}

@Test func checksAgainOnEveryLaunchWithoutRedownloadingInstalledVersion() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let transport = Transport(metadata: try releases(fixture.original), payload: fixture.original)
    let updater = MCUIUpdater(fetch: { try await transport.get($0) })
    #expect(await fixture.check(updater) == .unchanged)
    #expect(await fixture.check(updater) == .unchanged)
    #expect(await transport.calls == 2)
}

@Test(arguments: ["checksum", "malformed", "wrongID", "incompatible", "older", "prerelease", "offline", "backupFailure"])
func rejectedUpdatePreservesInstalledBytes(reason: String) async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let payload = try reason == "malformed" ? Data("not a jar".utf8) : jar(
        version: reason == "older" ? "0.0.9" : "0.2.0",
        minecraft: reason == "incompatible" ? "26.4" : "26.3", id: reason == "wrongID" ? "different-mod" : "cleanmenu"
    )
    if reason == "backupFailure" { try Data().write(to: fixture.root.appendingPathComponent(".mcui-backups")) }
    let metadata = try releases(payload, digest: reason == "checksum" ? String(repeating: "0", count: 64) : nil,
                                prerelease: reason == "prerelease")
    let updater = MCUIUpdater(fetch: { url in
        if reason == "offline" { throw URLError(.notConnectedToInternet) }
        return url.host == "api.github.com" ? metadata : payload
    })
    let outcome = await fixture.check(updater)
    if case .updated = outcome { Issue.record("Rejected update was installed: \(reason)") }
    #expect(try Data(contentsOf: fixture.installed) == fixture.original)
}

@Test func concurrentLaunchChecksShareOneTransaction() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let payload = try jar(version: "0.2.0")
    let transport = Transport(metadata: try releases(payload), payload: payload)
    let updater = MCUIUpdater(fetch: { try await transport.get($0) })
    async let first = fixture.check(updater)
    async let second = fixture.check(updater)
    let outcomes = await [first, second]
    #expect(outcomes == [.updated("0.2.0"), .updated("0.2.0")])
    #expect(await transport.calls == 2)
}

@Test func duplicateCopiesAreNotModified() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    try fixture.original.write(to: fixture.root.appendingPathComponent("mods/mcui.jar"))
    let updater = MCUIUpdater(fetch: { _ in Issue.record("Should not access network"); return Data() })
    let result = await fixture.check(updater)
    if case .kept = result {} else { Issue.record("Expected duplicate-copy rejection") }
    #expect(try Data(contentsOf: fixture.installed) == fixture.original)
}

@Test func compatibilityPredicatesFailClosed() {
    #expect(MCUIUpdater.matches("26.3", requirement: ">=26.3 <26.4"))
    #expect(!MCUIUpdater.matches("26.4", requirement: ">=26.3 <26.4"))
    #expect(MCUIUpdater.matches("26.3.1", requirement: "26.3.x"))
    #expect(MCUIUpdater.matches("26.3", requirement: "~26.3"))
    #expect(!MCUIUpdater.matches("26.4", requirement: "~26.3"))
    #expect(!MCUIUpdater.matches("0.19.5", requirement: ">=0.20.0"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MCUI_LIVE_TEST"] == "1"))
func liveGitHubUpdateInTemporaryInstance() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    try jar(version: "0.0.1").write(to: fixture.installed)
    let updater = MCUIUpdater()
    let outcome = await fixture.check(updater)
    if case .updated = outcome {} else { Issue.record("Live update did not complete: \(outcome.message)") }
    #expect(try Data(contentsOf: fixture.installed) != fixture.original)
}

@Test(arguments: ["success", "checksum", "incompatible", "wrongID", "older", "offline", "conflict"])
func shaderUpdatesUseSameVerificationAndBackups(reason: String) async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.installed)
    let path = fixture.root.appendingPathComponent("mods/metal-shaders.jar")
    let original = try jar(version: "1.2.6-alpha", minecraft: "~26.3", id: "mcopt-metal")
    try original.write(to: path)
    let payload = try jar(version: reason == "older" ? "1.2.5-alpha" : "1.2.7-alpha", minecraft: reason == "incompatible" ? "~26.4" : "~26.3", id: reason == "wrongID" ? "wrong" : "mcopt-metal", breaks: reason == "conflict" ? ["sodium": "*"] : [:])
    var objects = try #require(JSONSerialization.jsonObject(with: releases(payload)) as? [[String: Any]])
    objects[0]["assets"] = [["name": "metal-shaders-1.2.7-alpha.jar", "size": payload.count,
                             "digest": "sha256:" + (reason == "checksum" ? String(repeating: "0", count: 64) : hash(payload)),
                             "browser_download_url": "https://github.com/metalnakls/minecraftmetalshaders/releases/download/v1.2.7/metal-shaders-1.2.7-alpha.jar"]]
    let metadata = try JSONSerialization.data(withJSONObject: objects)
    if reason == "conflict" { try jar(version: "1.0", id: "sodium").write(to: fixture.root.appendingPathComponent("mods/sodium.jar")) }
    let updater = MCUIUpdater(mod: .shaders, fetch: { url in
        #expect(url.absoluteString.contains("metalnakls/minecraftmetalshaders/"))
        if reason == "offline" { throw URLError(.notConnectedToInternet) }
        return url.host == "api.github.com" ? metadata : payload
    })
    let outcome = await fixture.check(updater)
    if reason == "success" {
        #expect(outcome == .updated("1.2.7-alpha"))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".shader-backups/" + hash(original) + ".jar")) == original)
    } else {
        if case .updated = outcome { Issue.record("Rejected shader was installed") }
        #expect(try Data(contentsOf: path) == original)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MCUI_LIVE_TEST"] == "1"))
func liveShaderGitHubUpdateInTemporaryInstance() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    try jar(version: "0.0.1-alpha", id: "mcopt-metal").write(to: fixture.installed)
    let outcome = await fixture.check(MCUIUpdater(mod: .shaders))
    if case .updated = outcome {} else { Issue.record("Live shader update failed: \(outcome.message)") }
}
