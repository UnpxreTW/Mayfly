//
//  VMHarness.swift
//  VMKit
//
//  Serial-queue lifecycle harness around a single VZVirtualMachine. Owns the
//  dispatch queue, the VM, and its delegate, and drives start/stop. Verified
//  against macOS 26.5 SDK + Swift 6.3.2.
//
//  KEY VERIFIED FACT (do not "fix" back to Error?):
//    -[VZVirtualMachine startWithCompletionHandler:] is NS_REFINED_FOR_SWIFT
//    with NS_SWIFT_ASYNC_NAME(start()). Under Swift 6.3.2 + macOS 26.5 SDK the
//    *refined synchronous* form's completion closure takes a
//    `Result<Void, Error>`, NOT an `Error?`. (Empirically: a closure typed
//    `(Error?)` makes the clang importer overload resolution crash with
//    "failed to produce diagnostic". `Result<Void, Error>` compiles clean.)
//    There is also an async form `try await vm.start()`.
//
//  Threading contract (from VZVirtualMachine.h): every property access and call
//  on the VM — including reading `state`/`canStart`, calling `start`, and
//  `requestStop` — MUST happen on the queue passed to
//  initWithConfiguration:queue:. The delegate callbacks are also invoked on that
//  queue. We funnel everything through `vmQueue`.
//

import Foundation
import Virtualization

/// Lifecycle events surfaced to the embedder (CLI/UI/MCP). Delivered on an
/// arbitrary queue; embedders should hop to their own context if needed.
public enum VMLifecycleEvent: Sendable {
    case starting
    case running
    /// Guest powered itself off cleanly (delegate `guestDidStop`).
    case guestStopped
    /// VM stopped due to an error (delegate `didStopWithError`) or a failed start.
    case stoppedWithError(String)
}

@available(macOS 13.0, *)
public final class VMHarness: NSObject, @unchecked Sendable {

    /// Serial queue that owns the VM. Label kept stable for ps/Instruments.
    private let vmQueue = DispatchQueue(label: "mayfly.vm")

    private let configuration: VZVirtualMachineConfiguration

    /// Constructed lazily on `vmQueue` inside `start()` so the VM is created on
    /// the same queue that operates it (cleanest with the framework contract).
    private var virtualMachine: VZVirtualMachine?

    /// Strong-held so the weak `vm.delegate` does not deallocate.
    private var delegateBox: DelegateBox?

    /// Caller-supplied event sink.
    private let onEvent: @Sendable (VMLifecycleEvent) -> Void

    /// Set once `requestStop`/`stop` has been issued so we don't double-stop.
    private var isStopping = false

    public init(
        configuration: VZVirtualMachineConfiguration,
        onEvent: @escaping @Sendable (VMLifecycleEvent) -> Void
    ) {
        self.configuration = configuration
        self.onEvent = onEvent
        super.init()
    }

    /// Convenience: build a harness straight from a `LinuxVMSpec` so embedders
    /// (CLI/UI/MCP) never need to import Virtualization or touch VZ types.
    /// Throws if configuration building/validation fails.
    public static func makeLinux(
        spec: LinuxVMSpec,
        onEvent: @escaping @Sendable (VMLifecycleEvent) -> Void
    ) throws -> VMHarness {
        let configuration = try LinuxVMConfigurationBuilder.makeConfiguration(from: spec)
        return VMHarness(configuration: configuration, onEvent: onEvent)
    }

    /// Whether the framework reports virtualization is available at all.
    /// Cheap, queue-agnostic class property.
    public static var isVirtualizationSupported: Bool {
        VZVirtualMachine.isSupported
    }

    /// Start the VM. Returns immediately; lifecycle is reported via `onEvent`.
    /// Safe to call from any queue.
    public func start() {
        vmQueue.async { [weak self] in
            guard let self else { return }

            let vm = VZVirtualMachine(configuration: self.configuration, queue: self.vmQueue)
            let box = DelegateBox(harness: self)
            vm.delegate = box
            self.virtualMachine = vm
            self.delegateBox = box

            guard vm.canStart else {
                self.onEvent(.stoppedWithError(
                    "VM not in a startable state (state=\(vm.state.rawValue))"))
                return
            }

            self.onEvent(.starting)

            // Refined synchronous start: completion closure is Result<Void, Error>.
            vm.start { [weak self] (result: Result<Void, Error>) in
                guard let self else { return }
                switch result {
                case .success:
                    self.onEvent(.running)
                case .failure(let error):
                    self.onEvent(.stoppedWithError(
                        Self.describeStartError(error)))
                }
            }
        }
    }

    /// Ask the guest to power off cleanly (ACPI-style). Falls back to a hard
    /// stop if the guest cannot be asked. Safe to call from any queue
    /// (e.g. a SIGINT handler hopping onto `vmQueue`).
    public func requestStop() {
        vmQueue.async { [weak self] in
            guard let self, let vm = self.virtualMachine, !self.isStopping else { return }
            self.isStopping = true

            if vm.canRequestStop {
                do {
                    try vm.requestStop()
                } catch {
                    self.hardStop(vm)
                }
            } else if vm.canStop {
                self.hardStop(vm)
            } else {
                // Already stopped / not running.
                self.onEvent(.guestStopped)
            }
        }
    }

    /// Destructive stop (no clean guest shutdown). Must run on `vmQueue`.
    private func hardStop(_ vm: VZVirtualMachine) {
        // stopWithCompletionHandler: is macOS 12+. Untyped Error? closure here
        // is fine — this one is NOT refined-for-Swift.
        vm.stop { [weak self] error in
            guard let self else { return }
            if let error {
                self.onEvent(.stoppedWithError(
                    "hard stop failed: \(error.localizedDescription)"))
            } else {
                self.onEvent(.guestStopped)
            }
        }
    }

    // MARK: - Delegate fan-in

    fileprivate func handleGuestDidStop() {
        onEvent(.guestStopped)
    }

    fileprivate func handleDidStop(withError error: Error) {
        onEvent(.stoppedWithError(error.localizedDescription))
    }

    /// Produce a human-readable description of a VZ start error, calling out the
    /// notorious VZErrorInternal (Code=1) case which is frequently the locked-
    /// keychain failure (see `KeychainPreflight`).
    static func describeStartError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == VZErrorDomain, nsError.code == VZError.Code.internalError.rawValue {
            return """
            VZErrorInternal (VZErrorDomain Code=1) during start. \
            Common cause on macOS 15+/26: no unlocked login keychain in this \
            session. Run KeychainPreflight.ensureLoginKeychainUnlocked() before \
            start(), or unlock the login keychain. Underlying: \
            \(nsError.localizedDescription)
            """
        }
        return "\(nsError.domain) Code=\(nsError.code): \(nsError.localizedDescription)"
    }
}

/// Concrete delegate. Kept separate from `VMHarness` so the harness can hold it
/// strongly while the VM holds it weakly (avoids the "immediately deallocated"
/// trap the compiler warns about when assigning a temporary to a weak property).
@available(macOS 13.0, *)
private final class DelegateBox: NSObject, VZVirtualMachineDelegate {
    private weak var harness: VMHarness?

    init(harness: VMHarness) {
        self.harness = harness
        super.init()
    }

    // Refined Swift name of -guestDidStopVirtualMachine:.
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        harness?.handleGuestDidStop()
    }

    // -virtualMachine:didStopWithError:.
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        harness?.handleDidStop(withError: error)
    }

    // -virtualMachine:networkDevice:attachmentWasDisconnectedWithError: (macOS 12+).
    // Optional; a disconnected NAT attachment is non-fatal for boot, so we log
    // via no-op here. Embedders that care can subclass/extend.
    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        // Intentionally non-fatal.
    }
}
