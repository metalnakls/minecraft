import AppKit
import Darwin

@main
struct MinecraftQuitTests {
    @MainActor static func main() {
        precondition(!MinecraftApplication.enqueueGameQuit(), "Missing SDL must fail safely")
        guard CommandLine.arguments.count == 2,
              let handle = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL) else {
            fatalError("Pass the installed libSDL3.dylib path")
        }
        defer { dlclose(handle) }
        typealias InitSDL = @convention(c) (UInt32) -> Bool
        typealias Poll = @convention(c) (UnsafeMutableRawPointer) -> Bool
        typealias Quit = @convention(c) () -> Void
        let initialize = unsafeBitCast(dlsym(handle, "SDL_Init")!, to: InitSDL.self)
        let poll = unsafeBitCast(dlsym(handle, "SDL_PollEvent")!, to: Poll.self)
        let quit = unsafeBitCast(dlsym(handle, "SDL_Quit")!, to: Quit.self)
        precondition(initialize(0x4000)) // SDL_INIT_EVENTS; no game or window.
        defer { quit() }
        precondition(MinecraftApplication.enqueueGameQuit())
        let event = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { event.deallocate() }
        var found = false
        while poll(event) {
            if event.load(as: UInt32.self) == 0x100 { found = true }
        }
        precondition(found, "The normal SDL quit event must reach the queue")
        print("PASS: missing SDL fails safely; installed SDL receives normal quit event")
    }
}
