import AppKit
import Darwin
import Foundation

/// Runs OpenJDK's launcher library inside Minecraft.app. The JVM owns its normal game loop.
@MainActor
enum NativeJavaRuntime {
    private typealias Launch = @convention(c) (
        Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UInt8, UInt8, UInt8, Int32
    ) -> Int32

    // libjli invokes the executable's main again on its launcher thread on macOS.
    // That entry must resume JLI directly, without reinitializing SwiftUI or profile loading.
    private struct Invocation {
        let launch: Launch
        let count: Int32
        let arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let names: [UnsafeMutablePointer<CChar>?]

        nonisolated func run() -> Int32 {
            launch(count, arguments, 0, nil, 0, nil,
                   UnsafePointer(names[0]), UnsafePointer(names[1]),
                   UnsafePointer(names[2]), UnsafePointer(names[3]), 0, 1, 0, 0)
        }
    }
    nonisolated(unsafe) private static var invocation: Invocation?

    nonisolated static func resumeLauncherThreadIfNeeded() {
        if let invocation { exit(invocation.run()) }
    }

    static func launch(
        javaExecutable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws {
        let javaHome = URL(fileURLWithPath: javaExecutable).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        let library = javaHome.appendingPathComponent("lib/libjli.dylib")
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_GLOBAL) else {
            throw launchError("Cannot load Java launcher: \(String(cString: dlerror()))")
        }
        guard let symbol = dlsym(handle, "JLI_Launch") else {
            dlclose(handle)
            throw launchError("Java runtime does not export JLI_Launch")
        }
        let launch = unsafeBitCast(symbol, to: Launch.self)
        guard FileManager.default.changeCurrentDirectoryPath(workingDirectory.path) else {
            dlclose(handle)
            throw launchError("Cannot open game directory: \(workingDirectory.path)")
        }
        for (key, value) in environment { setenv(key, value, 1) }
        setenv("JAVA_HOME", javaHome.path, 1)

        // Keep the Icon Composer bundle icon; Minecraft's SDL icon setter is opt-out in our mod.
        var options = arguments.filter {
            !$0.hasPrefix("-Xdock:icon=") && !$0.hasPrefix("-Xdock:name=")
        }
        if !options.contains("-XstartOnFirstThread") { options.insert("-XstartOnFirstThread", at: 0) }
        options.insert("-Dmcopt.app.preserveIcon=true", at: 0)
        var argv = ([javaExecutable] + options).map { strdup($0) } + [nil]
        let names = (["25", "25", "Minecraft", "java"] as [String]).map { strdup($0) }
        defer {
            argv.forEach { free($0) }
            names.forEach { free($0) }
        }
        // Only Option mode has launcher windows. Close those before the game creates its window.
        NSApp?.windows.forEach { $0.close() }
        let status = argv.withUnsafeMutableBufferPointer { buffer in
            let call = Invocation(launch: launch, count: Int32(buffer.count - 1),
                                  arguments: buffer.baseAddress!, names: names)
            invocation = call
            return call.run()
        }
        // The JVM cannot be restarted safely in this process after its main method exits.
        exit(status)
    }

    private static func launchError(_ message: String) -> GlobalError {
        .gameLaunch(i18nKey: "error.game_launch.process_failed", level: .popup, message: message)
    }
}
