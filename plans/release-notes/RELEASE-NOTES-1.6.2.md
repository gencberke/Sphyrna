# Sphyrna 1.6.2

Draft of 25 Oct 2026, for `@user`'s release (the push and the GitHub release wait for `@user`, [D-16](../../DECISIONS.md), [D-83](../../DECISIONS.md)). The release line is [D-93](../../DECISIONS.md); the work is [D-94](../../DECISIONS.md), [D-98](../../DECISIONS.md) and [D-99](../../DECISIONS.md), from [FEEDBACK-5](../archive/FEEDBACK-5.md).

1.6.2 gets Sphyrna ready for Codex. It shows where each agent stands, reads Codex's limits and models, and sets up a Mac that has neither agent ready. Codex sessions still cannot be started or resumed here; that comes with 1.7.0.

## Connections

- **A new Settings tab, Connections,** after General. It lists Claude Code and Codex, each with its version, whether it is found, who is signed in and whether its limits can be read. A switch connects or disconnects each one. Off, Sphyrna stops checking the agent, reading its usage and listing its models. It never signs the CLI out and never changes its settings, and sessions that exist keep working.
- **The detail** of the picked agent shows where the CLI is (Reveal), its version (up to date, update recommended, or update needed), the account (the email shows here and nowhere else), the profile folder, whether its limits can be read, and Check Again. A row says "Account changed" when a check finds another account than the one before, until you have seen the page.
- **Checks cost little.** They run when the page opens, when you come back to the app and when a session starts or ends, and no more often than every 5 minutes. Check Again always asks. Nothing runs on a timer and no model is called.
- **Deep Check** runs `claude doctor` or `codex doctor --no-color` and shows what it says. It runs only when you press it.
- **Install and Sign In** show the vendor's command with Copy and Open Terminal. Sphyrna never runs the command and never sees a password: you run it in Terminal, and Sphyrna checks again when you come back.
- **Connect your agents** replaces the "could not find Claude" notice on Home. On a first run it shows a card for each agent: Install, Sign In or Ready. Over a list of sessions it is one small card with Set Up…, shown while a connected agent is missing, signed out or too old. Codex never brings it up on its own in this version, because it cannot start.

## Usage

- **Limits and Tokens.** Settings → Usage has a switch between the two, which it remembers. With both agents connected, All, Claude and Codex pick what the page shows.
- **Limits** shows a card for each limit window of each agent: how much is left, a meter, when it resets, and for the 5-hour and the weekly window whether it lasts at this pace. A window of another length has the meter and no pace.
- **Tokens** gains Codex's card: the total for the period, a line per day and the lifetime total. It has no cost estimate, because Codex reports one total per day with no split by type.
- **Home and the footer chip** show Codex's windows too: under Claude's on Home's Plan limits card, and in the chip's tooltip.
- **Asking is event by event.** Codex is asked when the page opens and when you come back to the app while it shows, and Update asks again. Nothing asks in the background. Claude's limits now go through the same reader, so one process answers for the account and the windows.
- **Not in this version:** Claude's weekly windows for single models, a limits panel inside a session, and a notification when a limit resets.

## Models

- **The model popover lists Codex's models** as Codex reports them, with its three known names until it has answered. A model Codex hides is left out, and the group is left out while Codex is switched off. Codex models still cannot be picked for a session.

## Flow

- **Peek.** Rest the pointer on a session in the sidebar for a moment, and its tooltip shows your last ask and Claude's answer to it.
- **A session dropped on a terminal** pastes its transcript path, quoted for the shell, as a dropped file does. A session's own terminal does not take itself.

## Fixes

- **A streamed answer matches the finished one.** A code block inside a list item that ends at the left margin was read differently while it streamed. It now splits as the finished message does.
- **A long answer spaces its updates by what the last one cost,** also for an update that was already waiting when that cost was known.
- **Dragging a file out of Changes** no longer reads the disk each time the row is drawn.

## Going back to 1.6.1

1.6.2 adds two keys to the preferences file, the agent switches and the Usage section. 1.6.1 ignores them: every agent counts as connected there, and the Usage page is the one 1.6.1 had.
