import CoreGraphics
import XCTest
@testable import NASE

final class KeyboardRemapGateTests: XCTestCase {
    private func armedGate() -> KeyboardRemapGate {
        var gate = KeyboardRemapGate()
        gate.isArmed = true
        gate.remapsByPID = [4242: [NASEKeyCode.w: NASEKeyCode.upArrow]]
        gate.frontmostPID = 4242
        return gate
    }

    func testSubstitutesOnlyForTheFocusedGame() {
        XCTAssertEqual(armedGate().substitute(for: NASEKeyCode.w), NASEKeyCode.upArrow)
    }

    func testUnmappedKeyIsNeverSubstituted() {
        XCTAssertNil(armedGate().substitute(for: NASEKeyCode.k))
    }

    func testDisarmedGatePassesEverythingThrough() {
        var gate = armedGate()
        gate.isArmed = false
        XCTAssertFalse(gate.appliesToFocusedApplication)
        XCTAssertNil(gate.substitute(for: NASEKeyCode.w))
    }

    /// The whole point of the design: another app in front must be untouched.
    func testAnotherFocusedApplicationIsNotRemapped() {
        var gate = armedGate()
        gate.frontmostPID = 99
        XCTAssertFalse(gate.appliesToFocusedApplication)
        XCTAssertNil(gate.substitute(for: NASEKeyCode.w))
    }

    /// An exited game clears its PIDs, which must close the gate on its own so
    /// a remap can never outlive the game it was applied to.
    func testNoTrackedProcessesClosesTheGate() {
        var gate = armedGate()
        gate.remapsByPID = [:]
        XCTAssertFalse(gate.appliesToFocusedApplication)
        XCTAssertNil(gate.substitute(for: NASEKeyCode.w))
    }

    func testUnknownFrontmostProcessClosesTheGate() {
        var gate = armedGate()
        gate.frontmostPID = 0
        XCTAssertFalse(gate.appliesToFocusedApplication)
    }

    func testEmptyLayoutClosesTheGate() {
        var gate = armedGate()
        gate.remapsByPID = [4242: [:]]
        XCTAssertFalse(gate.appliesToFocusedApplication)
    }

    /// Two games running at once must not see each other's layout.
    func testEachGameSeesOnlyItsOwnLayout() {
        var gate = KeyboardRemapGate()
        gate.isArmed = true
        gate.remapsByPID = [
            100: [NASEKeyCode.w: NASEKeyCode.upArrow],
            200: [NASEKeyCode.w: NASEKeyCode.downArrow],
        ]

        gate.frontmostPID = 100
        XCTAssertEqual(gate.substitute(for: NASEKeyCode.w), NASEKeyCode.upArrow)

        gate.frontmostPID = 200
        XCTAssertEqual(gate.substitute(for: NASEKeyCode.w), NASEKeyCode.downArrow)
    }

    /// A game with no layout assigned is untouched even while another game in
    /// the same session list is being remapped.
    func testUnassignedGameIsNotRemapped() {
        var gate = KeyboardRemapGate()
        gate.isArmed = true
        gate.remapsByPID = [100: [NASEKeyCode.w: NASEKeyCode.upArrow]]
        gate.frontmostPID = 777
        XCTAssertFalse(gate.appliesToFocusedApplication)
        XCTAssertNil(gate.substitute(for: NASEKeyCode.w))
    }
}

final class KeyboardLayoutTests: XCTestCase {
    func testBuiltInLayoutsAreValid() throws {
        for layout in KeyboardLayout.builtIns {
            try layout.validate()
        }
    }

    func testWASDLayoutMapsAllFourDirections() {
        let table = KeyboardLayout.builtIn(id: "builtin.wasd-to-arrows")?.remapTable
        XCTAssertEqual(table?[NASEKeyCode.w], NASEKeyCode.upArrow)
        XCTAssertEqual(table?[NASEKeyCode.a], NASEKeyCode.leftArrow)
        XCTAssertEqual(table?[NASEKeyCode.s], NASEKeyCode.downArrow)
        XCTAssertEqual(table?[NASEKeyCode.d], NASEKeyCode.rightArrow)
        XCTAssertEqual(table?.count, 4)
    }

    func testRemapTableDropsIdentityMappings() {
        let layout = KeyboardLayout(
            id: "t", name: "T",
            remaps: [
                KeyRemap(from: NASEKeyCode.w, to: NASEKeyCode.w),
                KeyRemap(from: NASEKeyCode.a, to: NASEKeyCode.leftArrow),
            ]
        )
        XCTAssertEqual(layout.remapTable, [NASEKeyCode.a: NASEKeyCode.leftArrow])
    }

    func testDuplicateSourceKeyIsRejected() {
        let layout = KeyboardLayout(
            id: "t", name: "T",
            remaps: [
                KeyRemap(from: NASEKeyCode.w, to: NASEKeyCode.upArrow),
                KeyRemap(from: NASEKeyCode.w, to: NASEKeyCode.downArrow),
            ]
        )
        XCTAssertThrowsError(try layout.validate()) { error in
            XCTAssertEqual(
                error as? KeyboardLayoutValidationError,
                .duplicateSource("W")
            )
        }
    }

    func testIdentityRemapIsRejected() {
        let layout = KeyboardLayout(
            id: "t", name: "T",
            remaps: [KeyRemap(from: NASEKeyCode.w, to: NASEKeyCode.w)]
        )
        XCTAssertThrowsError(try layout.validate()) { error in
            XCTAssertEqual(error as? KeyboardLayoutValidationError, .identityRemap("W"))
        }
    }

    /// Modifiers are not in the catalog, so a layout can never be built that
    /// would try to rewrite one.
    func testModifierKeyCodeIsNotRemappable() {
        XCTAssertFalse(NASEKeyCode.isRemappable(55)) // Command
        XCTAssertFalse(NASEKeyCode.isRemappable(56)) // Shift
        XCTAssertFalse(NASEKeyCode.isRemappable(58)) // Option
        XCTAssertFalse(NASEKeyCode.isRemappable(59)) // Control
    }

    func testUnknownKeyIsRejected() {
        let layout = KeyboardLayout(
            id: "t", name: "T",
            remaps: [KeyRemap(from: 200, to: NASEKeyCode.upArrow)]
        )
        XCTAssertThrowsError(try layout.validate()) { error in
            XCTAssertEqual(error as? KeyboardLayoutValidationError, .unknownKey(200))
        }
    }

    func testEmptyLayoutIsRejected() {
        let layout = KeyboardLayout(id: "t", name: "T", remaps: [])
        XCTAssertThrowsError(try layout.validate()) { error in
            XCTAssertEqual(error as? KeyboardLayoutValidationError, .noRemaps)
        }
    }

    func testCatalogHasNoDuplicateKeyCodes() {
        let codes = NASEKeyCode.catalog.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count)
    }
}

final class KeyboardRemapPanicTests: XCTestCase {
    func testFirstPanicPressDisarms() {
        XCTAssertTrue(KeyboardRemapService.panicRequiresDisarm(
            panicCount: 1, lastSeen: 0, isEnabled: true
        ))
    }

    /// The regression this guards: the disarm must be consumed exactly once, so
    /// a later session poll cannot re-arm a remap the user panicked out of, and
    /// cannot keep forcing the toggle off either.
    func testPanicIsConsumedOnlyOnce() {
        XCTAssertFalse(KeyboardRemapService.panicRequiresDisarm(
            panicCount: 1, lastSeen: 1, isEnabled: true
        ))
    }

    func testPanicWhileAlreadyOffChangesNothing() {
        XCTAssertFalse(KeyboardRemapService.panicRequiresDisarm(
            panicCount: 4, lastSeen: 3, isEnabled: false
        ))
    }

    func testGateRecordsPanicSeparatelyFromBeingClosed() {
        var gate = KeyboardRemapGate()
        gate.frontmostPID = 1
        gate.remapsByPID = [1: [NASEKeyCode.w: NASEKeyCode.upArrow]]
        XCTAssertFalse(gate.appliesToFocusedApplication)
        XCTAssertEqual(gate.panicCount, 0)
    }
}

final class StoredGameSettingsCompatibilityTests: XCTestCase {
    /// `loadGameSettings` decodes with `try?` and falls back to an empty
    /// dictionary, so a field added without an optional type would silently
    /// discard every game's saved settings on upgrade.
    func testSettingsSavedBeforeKeyboardRemappingStillDecode() throws {
        let legacy = """
        {"launchArguments":"-windowed","workingDirectoryPath":"",
         "environmentText":"","graphicsBackend":"DXMT","launchExecutablePath":"",
         "customBannerPath":"","collection":"None","assignedBottleName":"",
         "assignedExternalPrefix":""}
        """
        let decoded = try JSONDecoder().decode(
            StoredGameSettings.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.launchArguments, "-windowed")
        XCTAssertNil(decoded.keyboardLayoutID)
    }

    func testKeyboardLayoutRoundTrips() throws {
        var settings = StoredGameSettings()
        settings.keyboardLayoutID = "builtin.wasd-to-arrows"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StoredGameSettings.self, from: data)
        XCTAssertEqual(decoded.keyboardLayoutID, "builtin.wasd-to-arrows")
    }
}

/// Drives the real tap callback with synthesized events. `handle` needs no
/// running tap, so these exercise the shipping hot path without Accessibility.
final class KeyboardRemapCallbackTests: XCTestCase {
    private let gamePID: pid_t = 5150

    private func tap(armed: Bool = true, frontmost: pid_t? = nil) -> KeyboardRemapTap {
        let tap = KeyboardRemapTap()
        tap.update {
            $0.isArmed = armed
            $0.remapsByPID = [self.gamePID: [NASEKeyCode.w: NASEKeyCode.upArrow]]
            $0.frontmostPID = frontmost ?? self.gamePID
        }
        return tap
    }

    private func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        return event
    }

    private func keyCode(of event: CGEvent) -> CGKeyCode {
        CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    }

    func testKeyDownIsRewrittenForTheFocusedGame() {
        let event = keyEvent(NASEKeyCode.w, down: true)
        let result = tap().handle(type: .keyDown, event: event)
        XCTAssertNotNil(result)
        XCTAssertEqual(keyCode(of: event), NASEKeyCode.upArrow)
    }

    /// keyUp must be rewritten by the same rule, or the game sees the original
    /// key go down and never come back up.
    func testKeyUpIsRewrittenIdentically() {
        let event = keyEvent(NASEKeyCode.w, down: false)
        _ = tap().handle(type: .keyUp, event: event)
        XCTAssertEqual(keyCode(of: event), NASEKeyCode.upArrow)
    }

    func testEventIsNeverSwallowed() {
        for code in [NASEKeyCode.w, NASEKeyCode.k, CGKeyCode(49)] {
            let event = keyEvent(code, down: true)
            XCTAssertNotNil(
                tap().handle(type: .keyDown, event: event),
                "handle must always return an event for key \(code)"
            )
        }
    }

    func testAnotherFocusedApplicationIsUntouched() {
        let event = keyEvent(NASEKeyCode.w, down: true)
        _ = tap(frontmost: 999).handle(type: .keyDown, event: event)
        XCTAssertEqual(keyCode(of: event), NASEKeyCode.w)
    }

    func testDisarmedTapIsUntouched() {
        let event = keyEvent(NASEKeyCode.w, down: true)
        _ = tap(armed: false).handle(type: .keyDown, event: event)
        XCTAssertEqual(keyCode(of: event), NASEKeyCode.w)
    }

    /// ⌘-combinations must survive so ⌘Q and ⌘Tab still work over a
    /// full-screen game.
    func testCommandCombinationIsNotRewritten() {
        let event = keyEvent(NASEKeyCode.w, down: true, flags: .maskCommand)
        _ = tap().handle(type: .keyDown, event: event)
        XCTAssertEqual(keyCode(of: event), NASEKeyCode.w)
    }

    func testPanicChordDisarmsAndPassesThrough() {
        let subject = tap()
        let event = keyEvent(
            NASEKeyCode.k,
            down: true,
            flags: [.maskControl, .maskAlternate, .maskCommand]
        )
        let result = subject.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result, "the panic chord must not be consumed")
        XCTAssertEqual(keyCode(of: event), NASEKeyCode.k)
        XCTAssertFalse(subject.snapshot.isArmed)
        XCTAssertEqual(subject.snapshot.panicCount, 1)

        // And remapping really has stopped.
        let after = keyEvent(NASEKeyCode.w, down: true)
        _ = subject.handle(type: .keyDown, event: after)
        XCTAssertEqual(keyCode(of: after), NASEKeyCode.w)
    }

    func testTapDisabledNotificationIsCountedForTheUI() {
        let subject = tap()
        _ = subject.handle(type: .tapDisabledByTimeout, event: keyEvent(NASEKeyCode.w, down: true))
        XCTAssertEqual(subject.snapshot.timeoutCount, 1)
    }
}

/// A rewritten event must be indistinguishable from a real press of the target
/// key. Setting only the key code leaves the Fn/numeric-pad flags and the
/// Unicode payload describing the key the user actually pressed, which produces
/// an event matching no real key — and a Wine game then sees nothing at all.
final class KeyboardRewriteFidelityTests: XCTestCase {
    private func event(_ code: CGKeyCode, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        return event
    }

    private func unicode(of event: CGEvent) -> [UniChar] {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        return Array(buffer.prefix(length))
    }

    func testRewritingToAnArrowAddsFunctionAndNumericPadFlags() {
        let subject = event(NASEKeyCode.w)
        KeyboardRemapTap.rewrite(event: subject, to: NASEKeyCode.upArrow)

        XCTAssertEqual(
            CGKeyCode(subject.getIntegerValueField(.keyboardEventKeycode)),
            NASEKeyCode.upArrow
        )
        XCTAssertTrue(subject.flags.contains(.maskSecondaryFn))
        XCTAssertTrue(subject.flags.contains(.maskNumericPad))
        XCTAssertEqual(unicode(of: subject), [0xF700])
    }

    func testRewritingAwayFromAnArrowClearsThoseFlags() {
        let subject = event(NASEKeyCode.upArrow, flags: [.maskSecondaryFn, .maskNumericPad])
        KeyboardRemapTap.rewrite(event: subject, to: NASEKeyCode.w)

        XCTAssertFalse(subject.flags.contains(.maskSecondaryFn))
        XCTAssertFalse(subject.flags.contains(.maskNumericPad))
        XCTAssertEqual(unicode(of: subject), [0x77]) // "w"
    }

    /// Shift must survive, or remapping would break shifted input.
    func testUnrelatedModifiersArePreserved() {
        let subject = event(NASEKeyCode.w, flags: [.maskShift])
        KeyboardRemapTap.rewrite(event: subject, to: NASEKeyCode.upArrow)
        XCTAssertTrue(subject.flags.contains(.maskShift))
    }

    func testFunctionKeyGetsFnFlagButNotNumericPad() {
        let subject = event(NASEKeyCode.w)
        KeyboardRemapTap.rewrite(event: subject, to: 122) // F1
        XCTAssertTrue(subject.flags.contains(.maskSecondaryFn))
        XCTAssertFalse(subject.flags.contains(.maskNumericPad))
        XCTAssertEqual(unicode(of: subject), [0xF704])
    }

    func testSpaceGetsItsOwnCharacterNotTheOriginalKeys() {
        let subject = event(NASEKeyCode.w)
        KeyboardRemapTap.rewrite(event: subject, to: 49) // Space
        XCTAssertEqual(unicode(of: subject), [0x20])
        XCTAssertFalse(subject.flags.contains(.maskSecondaryFn))
    }

    func testEveryCatalogKeyHasAUnicodePayload() {
        for entry in NASEKeyCode.catalog {
            XCTAssertNotNil(
                NASEKeyCode.traits(for: entry.code).unicode,
                "\(entry.name) (\(entry.code)) has no Unicode payload, so a rewrite to it would keep the original key's character"
            )
        }
    }
}
