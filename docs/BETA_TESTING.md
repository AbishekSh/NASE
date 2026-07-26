# Testing NASE

Thank you for helping test NASE. You do not need Xcode, Homebrew, a system
Python installation, or prior Wine experience. In fact, approaching NASE as a
normal Mac user is especially useful: if setup feels confusing, that is
important feedback.

Running a moderated interface test? Use the
[NASE Usability Test Guide](usability/README.md), which provides goal-based
participant tasks and a structured observation sheet without revealing where
controls are located.

NASE is still in active development. Use test accounts where practical and
avoid relying on it as the only copy of important game data or save files.

## Download and Install

1. Download the latest `NASE-*.dmg` from
   [GitHub Releases](https://github.com/AbishekSh/NASE-a-Windows-Steam-Wrapper-for-MacOS/releases).
2. Open the DMG and drag **NASE** into **Applications**.
3. Open NASE from Applications.
4. This test build is unsigned. If macOS blocks it:
   - Try opening NASE once.
   - Open **System Settings → Privacy & Security**.
   - Scroll to the security message about NASE and click **Open Anyway**.
   - Confirm that you want to open it.

Only bypass the warning for a DMG downloaded from the official NASE repository.

## Approach It Like a New User

Please begin without installing development tools or manually configuring
Wine. Let NASE explain and install its own managed requirements.

While using it, notice:

- Was it clear what NASE was asking you to do?
- Did you know what would happen before clicking a button?
- Did progress appear during long downloads or setup operations?
- Were error messages understandable without knowing Wine terminology?
- Could you tell whether a game was installing, launching, running, or closed?
- Did anything feel risky, surprising, repetitive, or unnecessarily technical?

Confusion is not user error. Tell us where it happened.

## Suggested Test Session

You do not need to complete every section. Report what you tried.

### 1. First launch and setup

- Launch NASE on a Mac that has not used it before.
- Follow the Setup Wizard without installing dependencies manually.
- Install the recommended DXMT environment.
- Confirm Steam opens and allows you to sign in.
- Quit and reopen NASE. The Setup Wizard should not restart unnecessarily.

Record any step that stalls, repeats, opens an unexpected window, or requires
Terminal.

### 2. Steam library and game lifecycle

- Install or select a small Steam game.
- Launch it from NASE.
- Confirm NASE changes from **Launching** to **Running**.
- Exit normally from inside the game.
- Confirm NASE recognizes that the game closed.
- Launch it again.
- Try **Stop** only when the game cannot close normally.

Pay special attention to games that leave NASE stuck on **Launching**, keep
Steam marked busy, or require **Stop All Wine Processes**.

### 3. Graphics profiles

- Start with the default DXMT profile.
- If you are comfortable experimenting, select Plain Wine, D3DMetal, or DXVK
  for one game.
- Confirm NASE explains that a missing profile is being prepared.
- Confirm the game files are reused instead of downloaded again.
- Delete an unused profile from **Settings → Compatibility** and verify the
  shared game remains installed.

If Steam reports that cloud saves cannot sync, record exactly when you closed
and reopened the game and which graphics profiles were involved.

### 4. Windows apps and installers

- Add a familiar Windows utility or installer, such as 7-Zip or Notepad++.
- Confirm it is clear whether you added an installer or the installed app.
- Complete installation and try to locate and add the installed executable.
- Close the app and confirm NASE notices it exited.

Some applications—especially modern Microsoft Store, WinRT, or graphics-heavy
.NET applications—may not work in Wine. A clear compatibility explanation is
still a successful product experience; a raw exception dialog is not.

### 5. Restart, recovery, and cleanup

- Quit NASE while no game is running, then reopen it.
- If comfortable, interrupt a download and retry it.
- Confirm your library, settings, and installed profiles remain available.
- Open **Settings → General → Uninstall NASE** and review both data-retention
  choices. Only complete the uninstall if you are finished testing.

## Reporting a Bug

Open a
[GitHub issue](https://github.com/AbishekSh/NASE-a-Windows-Steam-Wrapper-for-MacOS/issues/new)
with a short title describing what failed.

Please include:

```text
NASE version:
Mac model and chip:
macOS version:
Game or application:
Source: Steam / Epic / GOG / imported EXE / Mac
Graphics profile: DXMT / D3DMetal / DXVK / Plain Wine

What I tried:
What I expected:
What happened instead:
Can I reproduce it:
What fixed it, if anything:
```

Screenshots or a short screen recording are helpful. Include the relevant NASE
logs when available, but review them before posting.

Do **not** publish:

- passwords or authorization codes;
- Steam, Epic, or GOG session data;
- personal file paths you do not want public;
- crash reports or logs without checking them for private information.

## Suggesting an Improvement

Suggestions do not need to be technical. The most useful product feedback often
looks like:

```text
I was trying to:
I expected to find it under:
What confused or slowed me down:
What I would change:
Why that would help:
```

Tell us which words, controls, screens, or steps you would change. Mockups are
welcome but not required. If you stopped using NASE at any point, explain what
made you stop—that is especially valuable feedback.

## What a Successful Test Means

A test is useful even when a game does not run. NASE is succeeding when it:

- installs its own managed requirements;
- communicates progress clearly;
- preserves shared game files;
- tracks launches and exits correctly;
- recovers without forcing a full reinstall;
- explains compatibility failures in understandable language;
- leaves the tester in control of their data.
