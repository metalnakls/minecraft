//
//  GameLaunchUseCase.swift
//  GameFeature
//
//  © 2025-2026 Swift Craft Launcher Team. All rights reserved.
//

import Foundation
import Observation

/// A use case that manages launching and stopping a Minecraft game session.
@MainActor
@Observable
final class GameLaunchUseCase {
    /// Launches a Minecraft game session.
    /// - Parameters:
    ///   - player: The current player.
    ///   - game: The game version to launch.
    func launchGame(player: Player, game: GameVersionInfo) async {
        if game.modLoader.lowercased() == "fabric" {
            let settings = DIContainer.shared.ui.generalSettingsManager
            let minecraft = game.gameVersion.hasPrefix("Fabric ") ? String(game.gameVersion.dropFirst(7)) : game.gameVersion
            let outcome = await MCUIUpdater.shared.check(
                profile: AppPaths.profileDirectory(gameName: game.gameName),
                minecraft: minecraft, loader: game.modVersion, java: game.javaVersion,
                enabled: settings.autoUpdateMCUI
            )
            settings.mcuiUpdateStatus = outcome.message
            AppLog.game.info("\(outcome.message)")
        }
        var launchGame = game
        if !DIContainer.shared.system.javaManager.canJavaRun(at: launchGame.javaPath),
           let component = launchGame.javaRuntimeComponent {
            launchGame.javaPath = await DIContainer.shared.system.javaManager.ensureJavaExists(version: component)
        }

        let command = MinecraftLaunchCommand(player: player, game: launchGame)
        await command.launchGame()
    }

    /// Stops a running Minecraft game session.
    /// - Parameters:
    ///   - player: The current player, used to locate the process to stop.
    ///   - game: The game version to stop.
    func stopGame(player: Player, game: GameVersionInfo) async {
        let command = MinecraftLaunchCommand(player: player, game: game)
        await command.stopGame()
    }
}
