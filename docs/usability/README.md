# NASE Usability Test Guide

This is a moderated interface test, not a compatibility checklist. Give the
participant a goal, avoid explaining where controls are, and observe how they
try to complete it.

Use these documents together:

- [Participant Tasks](PARTICIPANT_TASKS.md): the goal cards shown to the tester.
- [Observation Notes](OBSERVATION_NOTES.md): one copy per test session.
- [Beta Testing Guide](../BETA_TESTING.md): installation and bug-report details
  provided after the usability session.

## What This Test Should Answer

- Can a new user understand what NASE is for?
- Can they add and install Windows software without understanding Wine?
- Can they distinguish an installer from the installed application?
- Can they launch, stop, configure, and troubleshoot a game?
- Do status labels match what the user believes is happening?
- Can users predict which data a destructive action will remove?
- Where do users hesitate, backtrack, or ask for help?

## Before the Session

Prepare:

- a clean or disposable macOS user account;
- the current NASE DMG;
- a harmless portable Windows `.exe`;
- a familiar Windows installer such as 7-Zip or Notepad++;
- a small Steam game if Steam testing is included;
- screen-recording permission from the participant;
- a fresh copy of [Observation Notes](OBSERVATION_NOTES.md).

Do not install Xcode, Homebrew, Python, Wine, or Winetricks for the participant.
The purpose is to see whether NASE handles and explains its own requirements.

Remove identifying information from the desktop and Finder before recording.
Use test accounts where practical.

## Opening Script

Read this without describing the interface:

> We are testing NASE, not you. There are no wrong answers. Please say what you
> are looking for, what you expect to happen, and anything that feels confusing.
> I may stay quiet while you work because I want to see what the interface
> communicates on its own. You may stop at any time.

Ask before recording:

> May I record the screen and your comments for product research? The recording
> will not be shared publicly.

## Moderating Without Leading

Good neutral prompts:

- “What are you thinking?”
- “What do you expect that to do?”
- “What are you looking for?”
- “What would you try next?”
- “What does that message mean to you?”
- “How confident are you that it worked?”

Avoid:

- naming the control they should use;
- pointing at an area of the screen;
- saying “correct,” “almost,” or “try Settings”;
- explaining Wine, bottles, prefixes, or graphics layers before the participant
  encounters those concepts;
- rescuing the participant immediately after an error.

If the participant is completely blocked, wait long enough to observe their
recovery attempts, mark the task as **assisted**, and give the smallest possible
hint. Record the exact hint.

## Running the Tasks

Show one task at a time from [Participant Tasks](PARTICIPANT_TASKS.md). Do not
show the moderator notes or later tasks.

Tasks 1–4 form the core session. The remaining tasks can be selected according
to available time and installed software. A typical session lasts 30–45
minutes.

After every task, ask:

1. “On a scale from 1 to 7, where 1 is very difficult and 7 is very easy, how
   was that task?”
2. “What, if anything, was confusing?”
3. “What did you expect to happen next?”

Record behavior before discussing design changes. What the participant did is
usually more reliable than what they remember doing.

## Outcome Ratings

Use one rating per task:

- **Completed:** Reached the goal without help.
- **Completed with difficulty:** Reached it without help but had substantial
  hesitation, backtracking, or recoverable errors.
- **Assisted:** Required a moderator hint.
- **Failed:** Could not reach the goal or reached an incorrect state.
- **Blocked by compatibility:** The interface path was understood, but the
  external app/game could not run.
- **Not attempted:** The task was intentionally skipped.

Do not count a Wine compatibility failure as a usability failure if NASE clearly
explains what happened and offers a reasonable next step.

## Debrief Questions

Ask after all tasks:

1. In your own words, what does NASE do?
2. What felt easiest?
3. What felt least trustworthy or most risky?
4. Which words or concepts were unfamiliar?
5. Where would you expect to manage an installed Windows app?
6. If a game failed, where would you look for help?
7. What is the first thing you would change?
8. Would you use NASE again? Why or why not?

## Turning Observations Into Changes

Prioritize evidence in this order:

1. repeated failures across participants;
2. destructive-action misunderstandings;
3. participants who confidently reached the wrong result;
4. repeated hesitation or backtracking;
5. stated preferences and visual polish suggestions.

For each finding, write:

```text
Observation:
Likely interface cause:
User impact:
Evidence:
Proposed change:
How we will retest it:
```

Avoid treating one participant’s proposed solution as the requirement. Preserve
the underlying problem they experienced, then compare possible solutions.
