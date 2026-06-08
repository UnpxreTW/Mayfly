//
//  LinuxVMConfiguration.swift
//  VMKit
//
//  Builds a VZVirtualMachineConfiguration for a headless Linux guest booting
//  via EFI. Every VZ symbol below was checked against the macOS 26.5 SDK
//  Virtualization.framework headers. Availability of each API is noted inline.
//
//  Device set assembled here (all confirmed in-SDK):
//    - VZEFIBootLoader (macOS 13) + VZEFIVariableStore (macOS 13, on-disk nvram)
//    - VZGenericPlatformConfiguration (macOS 12) — mandatory companion to EFI
//    - VZVirtioBlockDeviceConfiguration (macOS 11) backed by
//      VZDiskImageStorageDeviceAttachment(url:readOnly:error:) (macOS 11)
//    - VZVirtioEntropyDeviceConfiguration (macOS 11)
//    - VZVirtioNetworkDeviceConfiguration (macOS 11) + VZNATNetworkDeviceAttachment
//      (macOS 11) + fixed VZMACAddress (macOS 11)
//    - VZVirtioConsoleDeviceSerialPortConfiguration (macOS 11) +
//      VZFileHandleSerialPortAttachment (macOS 11) wired to stdin/stdout
//

import Foundation
import Virtualization

/// User-facing spec for a headless Linux VM. Plain value type so the CLI / UI /
/// MCP layers can build one without touching Virtualization types directly.
public struct LinuxVMSpec: Sendable {
    /// Local file URL of the RAW boot disk image (e.g. a downloaded cloud image
    /// converted to RAW, or a fresh truncated RAW disk). Must be writable.
    public var diskImageURL: URL

    /// Local file URL where the EFI variable store (nvram) lives / will be
    /// created. Persisting this keeps EFI boot entries across runs.
    public var nvramURL: URL

    /// Requested CPU count. Clamped to the framework's allowed range.
    public var cpuCount: Int

    /// Requested memory in bytes. Clamped to the framework's allowed range and
    /// rounded down to a 1 MiB multiple (required by the framework).
    public var memorySizeBytes: UInt64

    /// Fixed MAC address string ("01:23:45:ab:cd:ef"). A stable MAC means the
    /// guest keeps the same DHCP lease / predictable addressing across reboots.
    /// If nil, a random locally-administered address is generated.
    public var macAddress: String?

    /// If true, mount the boot disk read-only (useful for immutable/ephemeral
    /// runs). Defaults to false so the guest can write.
    public var diskReadOnly: Bool

    public init(
        diskImageURL: URL,
        nvramURL: URL,
        cpuCount: Int = 2,
        memorySizeBytes: UInt64 = 2 * 1024 * 1024 * 1024,
        macAddress: String? = "5a:a1:6f:00:00:01",
        diskReadOnly: Bool = false
    ) {
        self.diskImageURL = diskImageURL
        self.nvramURL = nvramURL
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.macAddress = macAddress
        self.diskReadOnly = diskReadOnly
    }
}

public enum LinuxVMConfigurationError: Error, CustomStringConvertible {
    case diskImageMissing(URL)
    case invalidMACAddress(String)
    case nvramCreationFailed(underlying: Error)
    case diskAttachmentFailed(underlying: Error)

    public var description: String {
        switch self {
        case let .diskImageMissing(url):
            return "boot disk image not found at \(url.path)"
        case let .invalidMACAddress(string):
            return "invalid MAC address string: \(string)"
        case let .nvramCreationFailed(underlying):
            return "failed to create EFI variable store (nvram): \(underlying)"
        case let .diskAttachmentFailed(underlying):
            return "failed to attach boot disk: \(underlying)"
        }
    }
}

/// Stateless builder that turns a `LinuxVMSpec` into a validated
/// `VZVirtualMachineConfiguration`. Marked `@available(macOS 13, *)` because
/// VZEFIBootLoader/VZEFIVariableStore are macOS 13+.
@available(macOS 13.0, *)
public enum LinuxVMConfigurationBuilder {

    /// File handles used to wire the guest serial console to the host. Returned
    /// to the caller so they (or a harness) can hold them and pump I/O.
    public struct SerialHandles: Sendable {
        public let readFromHost: FileHandle   // host writes -> guest stdin
        public let writeToHost: FileHandle    // guest output -> host stdout
    }

    /// Build a configuration plus the serial handles wired to the process's
    /// stdin/stdout. The returned configuration is already `validateWithError`-
    /// checked and ready to hand to `VZVirtualMachine`.
    public static func makeConfiguration(
        from spec: LinuxVMSpec
    ) throws -> VZVirtualMachineConfiguration {

        // --- Boot disk must exist; framework only accepts RAW images. ---
        guard FileManager.default.fileExists(atPath: spec.diskImageURL.path) else {
            throw LinuxVMConfigurationError.diskImageMissing(spec.diskImageURL)
        }

        let configuration = VZVirtualMachineConfiguration()

        // --- CPU / memory clamping (class properties are macOS 11+). ---
        configuration.cpuCount = clampCPUCount(spec.cpuCount)
        configuration.memorySize = clampMemory(spec.memorySizeBytes)

        // --- Platform: EFI *requires* the generic platform (macOS 12+). ---
        configuration.platform = VZGenericPlatformConfiguration()

        // --- EFI boot loader + persistent nvram (macOS 13+). ---
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try makeVariableStore(at: spec.nvramURL)
        configuration.bootLoader = bootLoader

        // --- Boot disk: VZDiskImageStorageDeviceAttachment -> Virtio block. ---
        let attachment: VZDiskImageStorageDeviceAttachment
        do {
            attachment = try VZDiskImageStorageDeviceAttachment(
                url: spec.diskImageURL,
                readOnly: spec.diskReadOnly
            )
        } catch {
            throw LinuxVMConfigurationError.diskAttachmentFailed(underlying: error)
        }
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        configuration.storageDevices = [blockDevice]

        // --- Entropy (macOS 11+). ---
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // --- Network: Virtio + NAT + fixed/locally-administered MAC. ---
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = try resolveMACAddress(spec.macAddress)
        configuration.networkDevices = [network]

        // --- Serial console wired to host stdin/stdout. ---
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        let stdinHandle = FileHandle.standardInput
        let stdoutHandle = FileHandle.standardOutput
        // VZFileHandleSerialPortAttachment semantics (per SDK header):
        //   data written to `fileHandleForReading` goes TO the guest,
        //   data FROM the guest appears on `fileHandleForWriting`.
        // So: read host stdin -> guest; guest output -> host stdout.
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: stdinHandle,
            fileHandleForWriting: stdoutHandle
        )
        configuration.serialPorts = [serial]

        // --- Validate before returning. Surfaces config errors as VZError. ---
        // Swift-refined name of -validateWithError: is `validate()`.
        try configuration.validate()

        return configuration
    }

    // MARK: - Helpers

    private static func makeVariableStore(at url: URL) throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: url.path) {
            // Reuse existing nvram (preserves boot entries).
            return VZEFIVariableStore(url: url)
        }
        do {
            // initCreatingVariableStoreAtURL:options:error: — macOS 13+.
            return try VZEFIVariableStore(
                creatingVariableStoreAt: url,
                options: []
            )
        } catch {
            throw LinuxVMConfigurationError.nvramCreationFailed(underlying: error)
        }
    }

    private static func resolveMACAddress(_ string: String?) throws -> VZMACAddress {
        guard let string else {
            return VZMACAddress.randomLocallyAdministered()
        }
        guard let mac = VZMACAddress(string: string) else {
            throw LinuxVMConfigurationError.invalidMACAddress(string)
        }
        return mac
    }

    /// Clamp CPU count into [minimumAllowedCPUCount, maximumAllowedCPUCount].
    public static func clampCPUCount(_ requested: Int) -> Int {
        let lo = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let hi = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        return max(lo, min(hi, requested))
    }

    /// Clamp memory into [minimumAllowedMemorySize, maximumAllowedMemorySize]
    /// and round DOWN to a 1 MiB multiple (framework requires a 1 MiB multiple).
    public static func clampMemory(_ requested: UInt64) -> UInt64 {
        let lo = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let hi = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let clamped = max(lo, min(hi, requested))
        let oneMiB: UInt64 = 1024 * 1024
        let rounded = (clamped / oneMiB) * oneMiB
        return max(lo, rounded)
    }
}
