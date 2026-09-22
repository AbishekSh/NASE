import CoreGraphics
import Foundation

/// One physical-key substitution.
///
/// Keys are stored as macOS *physical* key codes rather than characters, so a
/// layout means the same thing on every keyboard layout. That matches how games
/// treat WASD-style bindings, and it is what `winemac.drv` passes through to
/// Windows virtual keys.
struct KeyRemap: Codable, Hashable, Identifiable {
    var from: CGKeyCode
    var to: CGKeyCode

    var id: CGKeyCode { from }

    init(from: CGKeyCode, to: CGKeyCode) {
        self.from = from
        self.to = to
    }
}

/// A named set of substitutions the user can apply to a game.
struct KeyboardLayout: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var remaps: [KeyRemap]
    var isBuiltIn: Bool

    init(id: String, name: String, remaps: [KeyRemap], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.remaps = remaps
        self.isBuiltIn = isBuiltIn
    }

    /// The form the event tap reads. Building it once keeps the tap callback to
    /// a single dictionary lookup.
    var remapTable: [CGKeyCode: CGKeyCode] {
        var table: [CGKeyCode: CGKeyCode] = [:]
        for remap in remaps where remap.from != remap.to {
            table[remap.from] = remap.to
        }
        return table
    }

    /// Spelling out the direction once, above a list of compact bindings, is
    /// what keeps `W → Up Arrow` from being read backwards.
    static let directionLegend = "Key you press → key the game receives"

    var summary: String {
        guard !remaps.isEmpty else { return "No substitutions" }
        return remaps
            .map { "\(NASEKeyCode.displayName(for: $0.from)) → \(NASEKeyCode.displayName(for: $0.to))" }
            .joined(separator: ", ")
    }
}

enum KeyboardLayoutValidationError: LocalizedError, Equatable {
    case emptyName
    case noRemaps
    case duplicateSource(String)
    case identityRemap(String)
    case unknownKey(CGKeyCode)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Give this layout a name."
        case .noRemaps:
            return "Add at least one key substitution."
        case .duplicateSource(let key):
            return "\(key) is remapped more than once. Each key can only be remapped to one other key."
        case .identityRemap(let key):
            return "\(key) is mapped to itself, which has no effect."
        case .unknownKey(let code):
            return "Key code \(code) is not a key NASE can remap."
        }
    }
}

extension KeyboardLayout {
    /// Reject a layout before it can reach the tap.
    ///
    /// A layout that silently misbehaves is worse than one that refuses to
    /// load, because the user's own keyboard is what they would have to
    /// diagnose it with.
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeyboardLayoutValidationError.emptyName
        }
        guard !remaps.isEmpty else {
            throw KeyboardLayoutValidationError.noRemaps
        }
        var seen = Set<CGKeyCode>()
        for remap in remaps {
            guard NASEKeyCode.isRemappable(remap.from) else {
                throw KeyboardLayoutValidationError.unknownKey(remap.from)
            }
            guard NASEKeyCode.isRemappable(remap.to) else {
                throw KeyboardLayoutValidationError.unknownKey(remap.to)
            }
            guard remap.from != remap.to else {
                throw KeyboardLayoutValidationError.identityRemap(
                    NASEKeyCode.displayName(for: remap.from)
                )
            }
            guard seen.insert(remap.from).inserted else {
                throw KeyboardLayoutValidationError.duplicateSource(
                    NASEKeyCode.displayName(for: remap.from)
                )
            }
        }
    }
}

/// Physical key codes NASE is willing to remap, with display names.
///
/// Modifier keys are deliberately absent: the tap watches `keyDown`/`keyUp`
/// only, never `flagsChanged`, so modifiers cannot be rewritten and chords such
/// as ⌘Q keep working while a full-screen game is focused.
enum NASEKeyCode {
    static let a: CGKeyCode = 0
    static let s: CGKeyCode = 1
    static let d: CGKeyCode = 2
    static let w: CGKeyCode = 13
    static let k: CGKeyCode = 40
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126

    /// Every key the UI can offer, in a keyboard-ish reading order.
    static let catalog: [(code: CGKeyCode, name: String)] = [
        (50, "`"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"),
        (22, "6"), (26, "7"), (28, "8"), (25, "9"), (29, "0"),
        (27, "-"), (24, "="),

        (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (17, "T"), (16, "Y"),
        (32, "U"), (34, "I"), (31, "O"), (35, "P"), (33, "["), (30, "]"), (42, "\\"),

        (0, "A"), (1, "S"), (2, "D"), (3, "F"), (5, "G"), (4, "H"),
        (38, "J"), (40, "K"), (37, "L"), (41, ";"), (39, "'"),

        (6, "Z"), (7, "X"), (8, "C"), (9, "V"), (11, "B"), (45, "N"),
        (46, "M"), (43, ","), (47, "."), (44, "/"),

        (49, "Space"), (48, "Tab"), (36, "Return"), (51, "Delete"), (53, "Escape"),

        (123, "Left Arrow"), (124, "Right Arrow"), (125, "Down Arrow"), (126, "Up Arrow"),

        (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"), (117, "Forward Delete"),

        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
        (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
    ]

    private static let namesByCode: [CGKeyCode: String] = Dictionary(
        catalog.map { ($0.code, $0.name) },
        uniquingKeysWith: { first, _ in first }
    )

    static func isRemappable(_ code: CGKeyCode) -> Bool {
        namesByCode[code] != nil
    }

    static func displayName(for code: CGKeyCode) -> String {
        namesByCode[code] ?? "Key \(code)"
    }
}

/// What a genuine press of a key looks like beyond its key code.
///
/// macOS does not identify a key by its key code alone. Arrows and the
/// navigation cluster carry the Fn flag, arrows additionally carry the
/// numeric-pad flag, and every key carries a Unicode payload that consumers
/// read for text. Rewriting only the key code leaves the other fields
/// describing the *original* key, producing an event that has no real-world
/// equivalent — and `winemac.drv` can reject it rather than translate it.
struct NASEKeyTraits {
    var unicode: UniChar?
    var needsFunctionFlag: Bool
    var needsNumericPadFlag: Bool
}

extension NASEKeyCode {
    /// NSEvent's private-use scalars for keys with no printable character.
    private static let functionKeyUnicode: [CGKeyCode: UniChar] = [
        126: 0xF700, 125: 0xF701, 123: 0xF702, 124: 0xF703,   // arrows
        122: 0xF704, 120: 0xF705, 99: 0xF706, 118: 0xF707,    // F1-F4
        96: 0xF708, 97: 0xF709, 98: 0xF70A, 100: 0xF70B,      // F5-F8
        101: 0xF70C, 109: 0xF70D, 103: 0xF70E, 111: 0xF70F,   // F9-F12
        115: 0xF729, 119: 0xF72B, 116: 0xF72C, 121: 0xF72D,   // Home/End/PgUp/PgDn
        117: 0xF728,                                          // Forward Delete
    ]

    private static let controlKeyUnicode: [CGKeyCode: UniChar] = [
        49: 0x20,   // Space
        48: 0x09,   // Tab
        36: 0x0D,   // Return
        51: 0x7F,   // Delete
        53: 0x1B,   // Escape
    ]

    /// Keys macOS marks with the Fn flag.
    private static let functionFlagKeys: Set<CGKeyCode> = Set(functionKeyUnicode.keys)

    /// Keys macOS marks with the numeric-pad flag. Arrows only, among the keys
    /// in the catalog.
    private static let numericPadKeys: Set<CGKeyCode> = [123, 124, 125, 126]

    static func traits(for code: CGKeyCode) -> NASEKeyTraits {
        NASEKeyTraits(
            unicode: unicodeScalar(for: code),
            needsFunctionFlag: functionFlagKeys.contains(code),
            needsNumericPadFlag: numericPadKeys.contains(code)
        )
    }

    private static func unicodeScalar(for code: CGKeyCode) -> UniChar? {
        if let special = functionKeyUnicode[code] { return special }
        if let control = controlKeyUnicode[code] { return control }
        // Every remaining catalog entry is named by the single character it
        // types on a US layout.
        guard let name = catalog.first(where: { $0.code == code })?.name,
              name.count == 1,
              let scalar = name.lowercased().unicodeScalars.first,
              scalar.value <= UInt32(UInt16.max)
        else {
            return nil
        }
        return UniChar(scalar.value)
    }
}

extension KeyboardLayout {
    /// Layouts NASE ships. These are the vertical slice's test mappings: they
    /// need no capture UI, and WASD/arrow substitution is easy to confirm by
    /// eye inside a game.
    static let builtIns: [KeyboardLayout] = [
        KeyboardLayout(
            id: "builtin.wasd-to-arrows",
            name: "Play with WASD (game uses Arrow Keys)",
            remaps: [
                KeyRemap(from: NASEKeyCode.w, to: NASEKeyCode.upArrow),
                KeyRemap(from: NASEKeyCode.a, to: NASEKeyCode.leftArrow),
                KeyRemap(from: NASEKeyCode.s, to: NASEKeyCode.downArrow),
                KeyRemap(from: NASEKeyCode.d, to: NASEKeyCode.rightArrow),
            ],
            isBuiltIn: true
        ),
        KeyboardLayout(
            id: "builtin.arrows-to-wasd",
            name: "Play with Arrow Keys (game uses WASD)",
            remaps: [
                KeyRemap(from: NASEKeyCode.upArrow, to: NASEKeyCode.w),
                KeyRemap(from: NASEKeyCode.leftArrow, to: NASEKeyCode.a),
                KeyRemap(from: NASEKeyCode.downArrow, to: NASEKeyCode.s),
                KeyRemap(from: NASEKeyCode.rightArrow, to: NASEKeyCode.d),
            ],
            isBuiltIn: true
        ),
    ]

    static func builtIn(id: String) -> KeyboardLayout? {
        builtIns.first { $0.id == id }
    }
}
