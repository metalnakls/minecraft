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
            Task { @MainActor in
                let players = PlayerListViewModel()
                players.loadPlayersIfNeeded()
                let repository = GameRepository()
                await repository.loadInitialDataIfNeeded()
                if let player = players.currentPlayer, let game = repository.games.first {
                    await GameLaunchUseCase().launchGame(player: player, game: game)
                }
                // Missing setup or a preparation failure opens the launcher for recovery.
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
        }
        SwiftCraftLauncherApp.main()
    }
}
