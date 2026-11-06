import AppKit
import Foundation

/// Chooses game or launcher before SwiftUI creates any windows.
@main
@MainActor
enum MinecraftMain {
    static var awaitingPlayerSetup = false

    static func main() {
        NativeJavaRuntime.resumeLauncherThreadIfNeeded()
        _ = MinecraftApplication.shared
        // Exercise the shipped executable's JLI entrypoint without loading a profile.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-java" {
            _ = NSApplication.shared
            NativeJavaRuntime.preparingAtStartup = true
            do {
                try NativeJavaRuntime.launch(
                    javaExecutable: CommandLine.arguments[2], arguments: ["-version"],
                    workingDirectory: FileManager.default.temporaryDirectory, environment: [:]
                )
                NativeJavaRuntime.preparingAtStartup = false
                NativeJavaRuntime.runPreparedGameIfNeeded()
            } catch {
                print("Java handoff failed: \(error.localizedDescription)")
                exit(1)
            }
            return
        }
        DIContainer.shared.system.sparkleUpdateService.scheduleStartupCheckIfNeeded()
        if !NSEvent.modifierFlags.contains(.option),
           !CommandLine.arguments.contains("--launcher") {
            _ = NSApplication.shared
            NativeJavaRuntime.preparingAtStartup = true
            Task { @MainActor in
                let players = PlayerListViewModel()
                players.loadPlayersIfNeeded()
                awaitingPlayerSetup = players.currentPlayer == nil
                let repository = GameRepository()
                await repository.loadInitialDataIfNeeded()
                if let player = players.currentPlayer, let game = repository.games.first {
                    await GameLaunchUseCase().launchGame(player: player, game: game)
                }
                // Missing setup or a preparation failure opens the launcher for recovery.
                NativeJavaRuntime.preparingAtStartup = false
            }
            while NativeJavaRuntime.preparingAtStartup {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            NativeJavaRuntime.runPreparedGameIfNeeded()
        }
        SwiftCraftLauncherApp.main()
    }
}
