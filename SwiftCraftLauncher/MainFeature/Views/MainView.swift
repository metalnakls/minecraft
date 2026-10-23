//
//  MainView.swift
//  MainFeature
//
//  © 2025-2026 Swift Craft Launcher Team. All rights reserved.
//

import AppKit
import SwiftUI
import TouchBarSupport

/// Root navigation view that orchestrates the sidebar, content, and detail columns.
struct MainView: View {
    var shouldAutoLaunchGameAtStartup = true

    @Environment(DIContainer.self)
    var container
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var filterState = ResourceFilterState()
    @State private var detailState = ResourceDetailState()
    @State private var navigationHandler: SidebarNavigationHandler?
    @State private var didHandleAutoLaunch = false
    @Environment(GameRepository.self)
    private var gameRepository
    @Environment(GameLaunchUseCase.self)
    private var gameLaunchUseCase
    @Environment(PlayerListViewModel.self)
    private var playerListViewModel
    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 168, ideal: 168, max: 260)
        } content: {
            contentView
        } detail: {
            detailView
        }
        .environment(filterState)
        .environment(detailState)
        .modPackImportSheet()
        .onChange(of: detailState.selectedItem) { oldValue, newValue in
            navigationHandler?.handleSidebarItemChange(from: oldValue, to: newValue)
        }
        .onChange(of: container.core.selectedGameManager.selectedGameId) { _, newId in
            guard let gameId = newId else { return }
            if case .game(gameId) = detailState.selectedItem {
                return
            }
            detailState.selectedItem = .game(gameId)
        }
        .onChange(of: gameRepository.workingPathChanged) { _, _ in
            detailState.selectedItem = .resource(.mod)
            detailState.gameType = true
        }
        .task {
            navigationHandler = SidebarNavigationHandler(
                filterState: filterState,
                detailState: detailState,
                gameRepository: gameRepository,
                container: container,
            )
            await loadInitialAppData()
            await autoLaunchGameAtStartupIfNeeded()
        }
        .mainViewPresentations(container: container, detailState: detailState)
        .gameCrashAlert()
        .frame(minWidth: 900, minHeight: 500)
        .touchBarSupport(
            TouchBarSupportConfiguration.make(
                container: container,
                gameRepository: gameRepository,
                gameLaunchUseCase: gameLaunchUseCase,
                playerListViewModel: playerListViewModel,
            ) { openSettings() },
        )
    }

    @MainActor
    private func loadInitialAppData() async {
        playerListViewModel.loadPlayersIfNeeded()
        await gameRepository.loadInitialDataIfNeeded()

        if let firstGame = gameRepository.games.first {
            detailState.selectedItem = .game(firstGame.id)
        }
    }

    @MainActor
    private func autoLaunchGameAtStartupIfNeeded() async {
        guard !didHandleAutoLaunch else { return }
        didHandleAutoLaunch = true

        guard shouldAutoLaunchGameAtStartup,
              let player = playerListViewModel.currentPlayer,
              let game = gameRepository.games.first else { return }

        let gameStatusManager = container.core.gameStatusManager
        guard !gameStatusManager.isGameRunning(gameId: game.id, userId: player.id) else { return }

        gameStatusManager.setGameLaunching(gameId: game.id, userId: player.id, isLaunching: true)
        defer { gameStatusManager.setGameLaunching(gameId: game.id, userId: player.id, isLaunching: false) }

        await gameLaunchUseCase.launchGame(player: player, game: game)

    }
}
