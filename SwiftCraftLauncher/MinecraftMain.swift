import AppKit
import Foundation

/// Chooses game or launcher before SwiftUI creates any windows.
@main
@MainActor
enum MinecraftMain {
    static func main() {
        NativeJavaRuntime.resumeLauncherThreadIfNeeded()
        if !NSEvent.modifierFlags.contains(.option),
           !CommandLine.arguments.contains("--launcher") {
            _ = NSApplication.shared
            NativeJavaRuntime.preparingAtStartup = true
            Task { @MainActor in
                let players = PlayerListViewModel()
                players.loadPlayersIfNeeded()
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
