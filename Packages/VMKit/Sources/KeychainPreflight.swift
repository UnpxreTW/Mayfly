//
//  KeychainPreflight.swift
//  VMKit
//
//  Preflight that ensures an *unlocked* login keychain exists before a VM is
//  started. Background / research finding: on macOS 15+ (and observed on
//  macOS 26), VZVirtualMachine.start() can fail with
//      Error Domain=VZErrorDomain Code=1 (VZErrorInternal)
//  when the calling session has no unlocked login keychain — the framework
//  reaches into the keychain (the ad-hoc/derived signing identity material and
//  per-host save/restore encryption keys live there) during start. This is most
//  commonly hit from headless contexts: ssh sessions, launchd agents, CI runners
//  — anywhere there is no GUI login that has already unlocked
//  ~/Library/Keychains/login.keychain-db.
//
//  This file shells out to the `security` tool. That is deliberate: the
//  Security.framework SecKeychain* C API for unlock/create is deprecated and
//  noisy to call from Swift 6 concurrency-checked code, whereas `security
//  unlock-keychain` is stable, present on every macOS, and does exactly what we
//  need. We never write the password to disk and never log it.
//

import Foundation

public enum KeychainPreflightError: Error, CustomStringConvertible {
    /// `security` exited non-zero. `stderr` is captured for diagnostics.
    case securityToolFailed(command: String, status: Int32, stderr: String)
    /// We needed a password to unlock but none was available
    /// (no `MAYFLY_KEYCHAIN_PASSWORD`, no interactive prompt allowed).
    case passwordUnavailable
    /// `/usr/bin/security` is missing (should never happen on macOS).
    case securityToolMissing

    public var description: String {
        switch self {
        case let .securityToolFailed(command, status, stderr):
            return "`security` failed (exit \(status)) running `\(command)`: \(stderr)"
        case .passwordUnavailable:
            return "login keychain is locked and no unlock password was provided"
        case .securityToolMissing:
            return "/usr/bin/security not found"
        }
    }
}

/// Ensures the login keychain is present and unlocked before VM start.
///
/// Typical usage from the harness, immediately before `start()`:
/// ```swift
/// try KeychainPreflight.ensureLoginKeychainUnlocked()
/// ```
public enum KeychainPreflight {

    private static let securityToolURL = URL(fileURLWithPath: "/usr/bin/security")

    /// Path to the per-user login keychain.
    /// macOS stores the SQLite-backed keychain as `login.keychain-db`; the
    /// `security` tool accepts both `login.keychain` and the `-db` form, so we
    /// pass the canonical `-db` path that actually exists on disk.
    public static var loginKeychainURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Keychains")
            .appendingPathComponent("login.keychain-db")
    }

    /// Run the full preflight.
    ///
    /// Strategy:
    /// 1. If the login keychain file does not exist, create it (needs a
    ///    password — see `resolvePassword`).
    /// 2. Try to unlock it. If `MAYFLY_KEYCHAIN_PASSWORD` is set we use it
    ///    non-interactively; otherwise we attempt an interactive unlock
    ///    (`security unlock-keychain` with no `-p`, which prompts on a TTY).
    /// 3. Mark it as a search-list keychain so the framework can find it.
    ///
    /// - Parameter allowInteractive: when true and no env password is present,
    ///   fall back to an interactive `security unlock-keychain` prompt. Set this
    ///   to `false` in fully unattended contexts (then a password env var is
    ///   mandatory).
    public static func ensureLoginKeychainUnlocked(allowInteractive: Bool = true) throws {
        guard FileManager.default.fileExists(atPath: securityToolURL.path) else {
            throw KeychainPreflightError.securityToolMissing
        }

        let keychainPath = loginKeychainURL.path
        let password = resolvePassword()

        // 1. Create the keychain if missing.
        if !FileManager.default.fileExists(atPath: keychainPath) {
            guard let password else {
                throw KeychainPreflightError.passwordUnavailable
            }
            try run(arguments: ["create-keychain", "-p", password, keychainPath],
                    redactArgumentAtIndex: 2)
            // Ensure it is on the search list after creation.
            try addToSearchList(keychainPath)
        }

        // 2. Unlock.
        if let password {
            try run(arguments: ["unlock-keychain", "-p", password, keychainPath],
                    redactArgumentAtIndex: 2)
        } else if allowInteractive {
            // No `-p`: `security` prompts on the controlling TTY. If there is no
            // TTY this returns non-zero and we surface that.
            try run(arguments: ["unlock-keychain", keychainPath])
        } else {
            throw KeychainPreflightError.passwordUnavailable
        }
    }

    /// Resolve an unlock password from the environment, if present.
    /// We intentionally only support an env var (not a file) to keep the secret
    /// out of the filesystem.
    private static func resolvePassword() -> String? {
        let value = ProcessInfo.processInfo.environment["MAYFLY_KEYCHAIN_PASSWORD"]
        if let value, !value.isEmpty { return value }
        return nil
    }

    /// Add a keychain to the user's search list without clobbering existing
    /// entries. `security list-keychains -s` *replaces* the list, so we read the
    /// current list first and append.
    private static func addToSearchList(_ keychainPath: String) throws {
        let current = try captureSearchList()
        guard !current.contains(keychainPath) else { return }
        try run(arguments: ["list-keychains", "-d", "user", "-s"] + current + [keychainPath])
    }

    private static func captureSearchList() throws -> [String] {
        let output = try run(arguments: ["list-keychains", "-d", "user"])
        // Output lines look like:  "    "/path/to/keychain-db""
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// Run `/usr/bin/security` with the given arguments, returning stdout.
    /// `redactArgumentAtIndex` (if set) is replaced with "***" in the error/
    /// diagnostic command string so passwords never appear in logs.
    @discardableResult
    private static func run(arguments: [String], redactArgumentAtIndex redactIndex: Int? = nil) throws -> String {
        let process = Process()
        process.executableURL = securityToolURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outData, as: UTF8.self)
        if process.terminationStatus != 0 {
            var shown = arguments
            if let redactIndex, redactIndex < shown.count { shown[redactIndex] = "***" }
            throw KeychainPreflightError.securityToolFailed(
                command: "security " + shown.joined(separator: " "),
                status: process.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
        return stdout
    }
}
