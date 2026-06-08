//
//  VMRunLoop.swift
//  VMKit
//
//  Keeps a headless (no-AppKit) process alive while a VZVirtualMachine runs, and
//  installs a SIGINT handler for graceful shutdown.
//
//  RUNLOOP A/B TRADE-OFF (important, unresolved-by-docs, must be tested):
//
//    The Virtualization framework dispatches VM work and delegate callbacks onto
//    the queue you pass to initWithConfiguration:queue:. For those async blocks
//    to actually fire, *some* run loop / dispatch machinery has to be pumping.
//
//    Option A — bare CFRunLoop (this file's default for the CLI):
//        RunLoop.main.run() / CFRunLoopRun() on the main thread.
//        Pros: no AppKit dependency, smallest headless binary, no Dock icon, no
//        NSApplication activation policy fuss. Works for the common case because
//        the VM runs on its own serial queue (libdispatch), not on the main
//        run loop — the main run loop only needs to keep the process alive.
//        Risk (from research): some VZ internals have historically leaned on
//        AppKit/CFRunLoop modes that only get pumped under NSApplication. On
//        certain macOS versions the bare-runloop path has shown delegate
//        callbacks not firing / start completion never invoked. THIS IS THE
//        #1 thing to verify on the target machine tonight.
//
//    Option B — NSApplication.shared.run():
//        Run a full AppKit event loop with .accessory or .prohibited activation
//        policy (no Dock icon). Heavier, pulls in AppKit, but matches what
//        Apple's own sample "RunningLinuxInAVirtualMachine" effectively relies
//        on for GUI builds and is the most reliable way to guarantee all
//        run-loop modes VZ might use are serviced.
//
//    Strategy: ship A as default (clean CLI), expose B behind an env flag
//    (MAYFLY_USE_APPKIT_RUNLOOP=1) so we can A/B on the real host without a
//    rebuild. The GUI app target naturally uses AppKit already, so this concern
//    is CLI-only.
//

import Foundation

public enum VMRunLoop {

    /// Which run-loop strategy to use.
    public enum Strategy: Sendable {
        case bareRunLoop          // Option A
        case appKitApplication    // Option B (requires importing AppKit at call site)
    }

    /// Decide strategy from the environment. Defaults to `.bareRunLoop`.
    public static func strategyFromEnvironment() -> Strategy {
        if ProcessInfo.processInfo.environment["MAYFLY_USE_APPKIT_RUNLOOP"] == "1" {
            return .appKitApplication
        }
        return .bareRunLoop
    }

    /// Install a SIGINT (Ctrl-C) handler that runs `handler` on the next main
    /// run-loop tick. Uses a DispatchSource so the work happens off the signal
    /// context (you can't safely do much in a raw signal handler).
    ///
    /// Returns the source; the caller must retain it for the lifetime of the
    /// process (store it in a top-level `let`), otherwise it is cancelled.
    @discardableResult
    public static func installSIGINTHandler(
        _ handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceSignal {
        // Ignore the default SIGINT disposition so only our source sees it.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    /// Block the current (main) thread forever, pumping the main run loop.
    /// Used by the bare-run-loop strategy. Never returns; process exits via
    /// exit() from a handler.
    public static func runBareRunLoopForever() -> Never {
        // CFRunLoopRun services default + common modes; equivalent to
        // RunLoop.main.run() but unambiguous about the underlying CF call.
        CFRunLoopRun()
        // CFRunLoopRun returns only if no sources/timers are attached. Keep the
        // process alive defensively if that ever happens.
        while true { RunLoop.main.run(until: .distantFuture) }
    }
}
