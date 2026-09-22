# NASE Frontend Design

This document defines the product-facing UI direction for NASE. The goal is a calm native macOS library experience that exposes compatibility tools when needed without making Wine the center of every screen.

## Product hierarchy

The interface should answer these questions in order:

1. What games do I have?
2. Can I play or install this game?
3. What is NASE doing right now?
4. Where can I repair something when it goes wrong?

Backend paths, bottle names, renderer versions, and raw commands remain available in Settings, game details, and logs. They should not dominate the default library view.

## Action placement

- **Game actions** belong on the game card or in its overflow menu.
- **Source actions** such as Refresh, Open Steam, Epic Setup, and GOG Setup belong in the library header.
- **Add actions** belong in the library header for macOS and Wine sources.
- **Global status** belongs in the persistent sidebar command center. Broad recovery belongs in Help → Troubleshooting.
- **Configuration and advanced repair** belong in Settings.

**Stop All Windows Apps…** lives in Help → Troubleshooting and requires confirmation before closing Windows games, apps, and Steam across NASE bottles and the selected imported environment. Per-game Stop is the everyday control; when a game does not exit, NASE offers an explicit Force Quit choice for that session.

## Game cards

Cards use an artwork-first hierarchy:

1. Wide artwork
2. Source badge and primary Play/Install/Stop action
3. One game title
4. Install/launch state, collection, and compact secondary information
5. Overflow menu for non-primary actions

The title is not repeated over the artwork and again in the metadata area. Cards gain a subtle border and elevation on hover rather than changing layout. The primary action stays in a predictable bottom-right artwork position.

Only the Home library supports drag reordering. Store libraries do not attach drag gestures to cards, which keeps menus and buttons reliable.

The default grid favors compact cards capped at 420 points rather than stretching artwork across the available row. It calculates an explicit responsive column count and preserves spacing both between grid tracks and inside every cell, preventing expansive card content from consuming the visible gutter. Wide library windows therefore show more games at once, while the grid still collapses cleanly on narrow windows.

The library toolbar also offers a persistent Grid/List control. List mode uses compact artwork rows with title, source, status, collection, size, overflow actions, and the same primary Play/Install/Stop control. The selected layout applies consistently across sources and is remembered between launches.

## Progress and feedback

Every long-running action must have visible feedback:

- The sidebar command center shows the active backend job and a spinner.
- A dependency row replaces **Fix** with **Installing…** while that exact dependency is active.
- A Runtime Center row shows progress only for the runtime being installed.
- Epic and GOG setup sheets show installation progress in their client-install buttons.
- Completed and failed operations continue to appear in job history and logs.

Indeterminate progress is correct while a provider or system installer cannot report bytes or phases. Determinate progress should be used when the backend supplies a reliable fraction.

## Settings organization

Settings use a persistent section sidebar so users work with one concern at a time instead of navigating a single technical document:

- **General** contains application updates and the default Wine/bottle target.
- **Accounts** contains protected shared sign-in controls.
- **Compatibility** contains host readiness and graphics profiles.
- **Runtimes** contains managed engine installation and verification.
- **Jobs** contains current operations, structured results, cancellation, and recent history.
- **Advanced** contains repair tools, explicit paths, raw commands, logs, and validation output.

The Setup Wizard remains a global entry point. Testing settings automatically opens Advanced so validation output is visible, and active work can be opened directly from the section sidebar.

## Menus

The card overflow menu contains secondary operations only:

- details and settings
- pin/unpin
- store page and local files when available
- logs and debug launch for applicable sources
- update, verify, repair, and uninstall for installed Epic/GOG games

Provider-owned games cannot be removed from the account, so Epic and GOG cards do not show a misleading **Remove from Library** action. Hiding owned store titles should be implemented later as a separate NASE-local preference.

## Visual language

- Use a restrained dark neutral background and one green primary action color.
- Reserve red for destructive or emergency actions and orange for warnings.
- Prefer 12–14 point continuous corner radii for cards and grouped controls.
- Avoid duplicating labels or surrounding every control with a heavy border.
- Keep technical metadata secondary in size and contrast.
- Preserve keyboard focus, accessibility labels, tooltips, and adequate contrast.

## Next polish phases

1. Add user-selectable card density for grid mode.
2. Add skeleton artwork placeholders and an image cache for remote provider art.
3. Add NASE-local hide/unhide for Epic and GOG titles.
4. Add keyboard shortcuts for Search, Play, Refresh, Settings, and Stop Wine.
5. Test VoiceOver, keyboard-only navigation, light appearance, reduced motion, and small window sizes.
