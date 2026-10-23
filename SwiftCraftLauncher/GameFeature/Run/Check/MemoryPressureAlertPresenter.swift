//
//  MemoryPressureAlertPresenter.swift
//  GameFeature
//
//  © 2025-2026 Swift Craft Launcher Team. All rights reserved.
//

import AppKit
import Foundation

/// A choice the user makes when a memory pressure warning is shown.
enum MemoryPressureChoice: AlertChoice {
    /// Proceed with the launch despite elevated memory pressure.
    case continueAnyway
    /// Cancel the launch.
    case cancel
}

/// Presents a confirmation prompt when the system is under memory pressure before launch.
///
/// The main window observes ``isPresented`` and displays a modal. The launch
/// flow suspends until the user makes a choice or the prompt is dismissed.
@MainActor
@Observable
final class MemoryPressureAlertPresenter: AlertPresenter<MemoryPressureChoice> {
    private(set) var pressureLevel: MemoryPressureLevel = .normal

    func requestUserChoice(for level: MemoryPressureLevel) async -> MemoryPressureChoice {
        pressureLevel = level
        if NativeJavaRuntime.preparingAtStartup {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "game_launch.memory_pressure.title".localized()
            alert.informativeText = level.localizedMessage
            alert.addButton(withTitle: "common.continue".localized())
            alert.addButton(withTitle: "common.cancel".localized())
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn ? .continueAnyway : .cancel
        }
        return await requestUserChoice()
    }
}
