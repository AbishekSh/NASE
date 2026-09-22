import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Prints everything that decides whether keyboard remapping can run, then
/// exits.
///
/// Accessibility problems are invisible from inside the app: macOS lists every
/// build as "NASE", grants access per executable, and attributes a debugged
/// process to whatever launched it. Run `NASE --diagnose-input` to see the
/// actual state instead of inferring it.
enum KeyboardRemapDiagnostics {
    static let flag = "--diagnose-input"

    static func runAndExit() -> Never {
        var lines: [String] = ["NASE keyboard remap diagnostics", ""]

        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? ProcessInfo.processInfo.arguments.first
            ?? "unknown"
        lines.append("executable        : \(executable)")
        lines.append("bundle identifier : \(Bundle.main.bundleIdentifier ?? "(none - unbundled dev build)")")
        lines.append("code signature    : \(signatureSummary(path: executable))")
        lines.append("")

        // A debugged or terminal-launched process is attributed to its parent,
        // so the parent is often the process that actually needs the grant.
        let parent = parentProcessName()
        lines.append("launched by       : \(parent) (pid \(getppid()))")
        if let advice = attributionAdvice(for: parent) {
            lines.append("                    \(advice)")
        }
        lines.append("")

        let trusted = AXIsProcessTrusted()
        lines.append("AXIsProcessTrusted: \(trusted)")

        // Ground truth: AX trust is decided at launch, but the only capability
        // that matters is whether a tap can actually be created.
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        lines.append("event tap created : \(port != nil)")
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        lines.append("")

        let store = KeyboardLayoutStore.standard()
        let loaded = store.load()
        lines.append("layout file       : \(store.fileURL.path)")
        lines.append("built-in layouts  : \(KeyboardLayout.builtIns.map(\.name).joined(separator: ", "))")
        lines.append("user layouts      : \(loaded.layouts.isEmpty ? "(none)" : loaded.layouts.map(\.name).joined(separator: ", "))")
        if let warning = loaded.warning {
            lines.append("layout warning    : \(warning)")
        }
        lines.append("master switch     : \(UserDefaults.standard.bool(forKey: "input.keyboardRemapEnabled"))")
        lines.append("")

        lines.append("verdict           : \(verdict(trusted: trusted, tapCreated: port != nil))")

        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        exit(0)
    }

    private static func verdict(trusted: Bool, tapCreated: Bool) -> String {
        switch (trusted, tapCreated) {
        case (true, true):
            return "ready - remapping can run for this build"
        case (false, true):
            return "usable - AX trust is stale but a tap works, so remapping can run"
        case (true, false):
            return "trusted but macOS refused the tap; reopen this build"
        case (false, false):
            return "no access - enable THIS executable (and its launcher, above) in Accessibility"
        }
    }

    private static func attributionAdvice(for parent: String) -> String? {
        let lowered = parent.lowercased()
        if lowered.contains("debugserver") || lowered.contains("xcode") {
            return "-> debugged processes are attributed to Xcode, so Xcode must also be enabled in Accessibility"
        }
        if lowered.contains("terminal") || lowered.contains("iterm") || lowered.contains("code") || lowered.contains("zsh") || lowered.contains("bash") {
            return "-> terminal-launched processes may be attributed to the terminal app, which may also need enabling"
        }
        return nil
    }

    private static func parentProcessName() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", String(getppid())]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let name = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "unknown" : name
        } catch {
            return "unknown"
        }
    }

    private static func signatureSummary(path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", path]
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let signature = text.split(separator: "\n")
                .first { $0.hasPrefix("Signature=") }
                .map(String.init) ?? "unknown"
            return signature.replacingOccurrences(of: "Signature=", with: "")
        } catch {
            return "unknown"
        }
    }
}
