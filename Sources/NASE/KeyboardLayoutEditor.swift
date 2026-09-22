import AppKit
import CoreGraphics
import SwiftUI

/// One-shot physical key capture.
///
/// Reads `NSEvent.keyCode` — the physical key — rather than the typed
/// character, so a captured binding means the same thing on any keyboard
/// layout. The monitor is local and only installed while recording, and it
/// swallows the event so the keystroke cannot also drive the UI behind it.
struct KeyCaptureButton: View {
    @Binding var keyCode: CGKeyCode?
    @State private var isRecording = false
    @State private var monitor: Any?

    private static let escapeKeyCode: CGKeyCode = 53

    var body: some View {
        Button(label) {
            if isRecording { stopRecording() } else { startRecording() }
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 132)
        .onDisappear(perform: stopRecording)
        .help(isRecording ? "Press any key, or Escape to cancel" : "Click, then press a key")
    }

    private var label: String {
        if isRecording { return "Press a key…" }
        guard let keyCode else { return "Choose…" }
        return NASEKeyCode.displayName(for: keyCode)
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let captured = CGKeyCode(event.keyCode)
            // Escape cancels, so it is checked before the catalog and can never
            // be bound — which also keeps a way out of a mis-click.
            if captured == Self.escapeKeyCode {
                stopRecording()
                return nil
            }
            // Modifiers and exotic keys are not in the catalog, so they cannot
            // enter a layout at all.
            guard NASEKeyCode.isRemappable(captured) else { return nil }
            keyCode = captured
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

/// A binding being edited, before it becomes a `KeyRemap`.
private struct EditorBinding: Identifiable {
    let id = UUID()
    var from: CGKeyCode?
    var to: CGKeyCode?
}

/// Build or edit one user layout.
struct KeyboardLayoutEditor: View {
    let service: KeyboardRemapService
    /// The layout being edited, or nil to create a new one.
    let existing: KeyboardLayout?
    let onFinish: () -> Void

    @State private var name: String = ""
    @State private var bindings: [EditorBinding] = [EditorBinding()]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New Layout" : "Edit Layout")
                .font(.subheadline.weight(.semibold))

            TextField("Layout name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            HStack(spacing: 8) {
                Text("Key you press")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 132, alignment: .leading)
                Text("Key the game receives")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach($bindings) { $binding in
                    HStack(spacing: 8) {
                        KeyCaptureButton(keyCode: $binding.from)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        KeyCaptureButton(keyCode: $binding.to)
                        Spacer(minLength: 0)
                        Button {
                            bindings.removeAll { $0.id == binding.id }
                            if bindings.isEmpty { bindings = [EditorBinding()] }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this binding")
                    }
                }
            }

            Button {
                bindings.append(EditorBinding())
            } label: {
                Label("Add Binding", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { onFinish() }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            guard let existing else { return }
            name = existing.name
            bindings = existing.remaps.map { EditorBinding(from: $0.from, to: $0.to) }
            if bindings.isEmpty { bindings = [EditorBinding()] }
        }
    }

    private func save() {
        let remaps = bindings.compactMap { binding -> KeyRemap? in
            guard let from = binding.from, let to = binding.to else { return nil }
            return KeyRemap(from: from, to: to)
        }
        guard remaps.count == bindings.filter({ $0.from != nil || $0.to != nil }).count else {
            errorMessage = "Every binding needs both a key to replace and a key to send."
            return
        }
        let layout = KeyboardLayout(
            id: existing?.id ?? "user.\(UUID().uuidString)",
            name: name,
            remaps: remaps
        )
        do {
            try service.saveLayout(layout)
            onFinish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
