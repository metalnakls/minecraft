import AppKit
import Darwin

/// Native quit requests must go through the game's event loop, never exit AppKit directly.
@MainActor
final class MinecraftApplication: NSApplication {
    var gameRunning = false
    private var confirmingQuit = false
    private var quitRequested = false

    override func terminate(_ sender: Any?) {
        guard gameRunning else {
            super.terminate(sender)
            return
        }
        guard !confirmingQuit, !quitRequested else { return }
        confirmingQuit = true
        let alert = NSAlert()
        alert.messageText = "Save and quit Minecraft?"
        alert.informativeText = "Minecraft will save your singleplayer world before closing."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        let completion: (NSApplication.ModalResponse) -> Void = { [self] response in
            confirmingQuit = false
            guard response == .alertSecondButtonReturn else { return }
            quitRequested = Self.enqueueGameQuit()
            if !quitRequested {
                let error = NSAlert()
                error.messageText = "Minecraft could not quit safely"
                error.informativeText = "Use Save and Quit to Title in the game menu, then quit Minecraft."
                error.addButton(withTitle: "OK")
                if let window = mainWindow { error.beginSheetModal(for: window) }
                else { error.runModal() }
            }
        }
        if let window = mainWindow ?? keyWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// SDL3's public ABI: a 128-byte event union, with SDL_EVENT_QUIT at offset zero.
    /// Resolve the already-loaded library, including JVM libraries loaded RTLD_LOCAL.
    static func enqueueGameQuit() -> Bool {
        typealias PushEvent = @convention(c) (UnsafeMutableRawPointer) -> Bool
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index),
                  String(cString: name).hasSuffix("/libSDL3.dylib"),
                  let handle = dlopen(name, RTLD_LAZY | RTLD_NOLOAD) else { continue }
            defer { dlclose(handle) }
            guard let symbol = dlsym(handle, "SDL_PushEvent") else { continue }
            let push = unsafeBitCast(symbol, to: PushEvent.self)
            let event = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
            defer { event.deallocate() }
            event.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
            event.storeBytes(of: UInt32(0x100), as: UInt32.self)
            return push(event)
        }
        return false
    }
}
