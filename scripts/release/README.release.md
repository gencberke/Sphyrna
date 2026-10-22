<p align="center">
  <img src="assets/readme/icon.png" width="128" height="128" alt="Sphyrna's icon: a hammerhead drawn in white ASCII characters, climbing to the left on black">
</p>

<h1 align="center">Sphyrna</h1>

<p align="center">
  <b>Your Claude Code sessions, side by side, in one window on your Mac.</b><br>
  A native macOS app that starts, follows, resumes and stops real Claude Code sessions.
</p>

<p align="center">
  <a href="https://github.com/gencberke/loom/releases/latest">Download</a> ·
  <a href="#build-it-yourself">Build it yourself</a> ·
  macOS 27 · version @VERSION@
</p>

<p align="center">
  <img src="assets/readme/window.png" alt="The Sphyrna window: projects and their sessions with their live state in the sidebar, and the selected session on the Chat face while Claude works, with a subagent's card, an edit and a queued message">
</p>

## Why

Running several Claude Code sessions means several terminal tabs: one waits for your approval, one finished a while ago, one is still at work, and you find out by looking at each. Sphyrna puts them in one window. Every session sits in one sidebar under its project, with its state beside it, and the one you open fills the window while the others keep running.

Three things guide it:

- **Light.** Sphyrna stays out of the way of memory, CPU and battery. A hidden terminal does not draw, a stopped session keeps no process, and the animations stop while the window is hidden.
- **Sessions first.** Sphyrna is the one place for your sessions. A session can see the list of your other sessions, and can ask Sphyrna to open a new one, which starts only when you approve it.
- **Cost out of sight.** Sphyrna adds almost nothing to a session's context: beyond your project's own instructions, only a skill description of at most 300 characters (and a short output style in Ask mode). It calls a model only when you send or ask something, apart from two small calls: one to name a new Chat session, and Remora's morning brief, at most once a day.

## What it does

- **The real Claude Code.** Every session is your own, unmodified `claude` CLI in a process Sphyrna starts and owns. One setting chooses how sessions run: in **Chat**, a native view made for reading, or in the **terminal**, exactly as Claude Code draws it.
- **Live state at a glance.** Working, waiting for you, finished and not read yet, or failed: the same signs show in the sidebar, the tabs and the menu bar, and the Dock badge counts the sessions that need you.
- **Projects and tabs.** Sessions sit under their project, each project with its own tone. Keep the ones you switch between open as tabs.
- **Requests where you act.** An approval, a question or a plan waits above the composer with its choices. Return never answers one by accident.
- **Changes and subagents.** The inspector shows what the last turn, the whole session or the branch changed, and lists a session's subagents; click one to read its transcript while it works.
- **Resume anything.** Past sessions stay in the list, and Resume picks up the same session.
- **Remora on Home.** Home opens with a short brief of what moved in your sessions since you last looked. Ask Remora which session touched a file or what finished yesterday. Remora only reads: it never sends, starts or stops anything.
- **Sessions that open sessions.** A session can ask Sphyrna to start a new one for a task. Nothing starts until you approve it.
- **Usage without guesswork.** Your 5-hour and weekly plan limits first, then tokens per day and by model with an estimated cost, from Claude Code's own records on your Mac.
- **Clean exits.** Each session runs in its own process scope. Quit stops everything Sphyrna started, and nothing else.
- **Delete for real.** Deleting a session removes its local Claude Code data, and only its own.

## A look around

<p align="center">
  <img src="assets/readme/terminal.png" alt="A session on the terminal face, drawn by Claude Code itself, with the inspector's Overview: the session's state, model and mode, its context, worktree, last changes and running subagents">
</p>
<p align="center"><i>The same session on the terminal face, as Claude Code draws it, with the inspector beside it.</i></p>

<p align="center">
  <img src="assets/readme/agents.png" alt="The Agents tab: four subagents of a session in the chat, one of them waiting for approval, and an explorer's live transcript open in the inspector">
</p>
<p align="center"><i>A session's subagents. Click one to follow its transcript as it works.</i></p>

<p align="center">
  <img src="assets/readme/menu-bar.png" width="580" alt="Sphyrna's mark in the menu bar with its menu open: the session that needs you, the sessions at work, New Claude Session, Open Sphyrna, Settings and Quit Sphyrna">
</p>
<p align="center"><i>The menu bar mark shows when a session needs you, and its menu lists what waits and what is working.</i></p>

<p align="center">
  <img src="assets/readme/usage.png" width="460" alt="Settings, Usage: plan limits, the tokens of the last 7 days, tokens per day and usage by model">
</p>
<p align="center"><i>Plan limits first, then where the tokens went.</i></p>

<p align="center"><sub>The pictures are drawn from Sphyrna's design reference with made-up sample data.</sub></p>

## Install

1. Download `Loom-@VERSION@.zip` from the [latest release](https://github.com/gencberke/loom/releases/latest), unzip it and move **Loom.app** to `/Applications`. Finder, the Dock and the menu bar show it as Sphyrna.
2. The app is signed with a personal certificate but not notarized by Apple, so macOS blocks the downloaded copy. Clear the download flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Loom.app
   ```

3. Open Sphyrna, add a project folder and start a session.

You need macOS 27 on Apple silicon and [Claude Code](https://claude.com/claude-code) installed and signed in. Sphyrna starts sessions with the environment of your login shell, which has to be zsh (the macOS default), so `claude` has to work in a new Terminal window.

### Coming from Loom 0.4.4

Sphyrna is the new name of Loom from 1.6.0. Some names stay Loom on purpose, so that nothing you set up is lost:

- the app's bundle id, `local.loom.desktop`, so macOS keeps the permissions you gave Loom;
- the data folder, `~/Library/Application Support/Loom`, and the sockets in `~/.loom`, so your sessions, projects and settings are where they were;
- the app's file, `Loom.app`, and the download's name;
- this repository, `gencberke/loom`.

Replace the old `Loom.app` in `/Applications` with the new one; there is nothing to move.

## Build it yourself

You need macOS 27, Xcode with its Swift toolchain, and a code-signing identity. The build refuses ad-hoc signing so that macOS privacy permissions survive a rebuild. A self-signed certificate is enough: in Keychain Access choose **Certificate Assistant → Create a Certificate…**, name it `Loom Dev Code Signing`, pick **Self-Signed Root** and **Code Signing**, then set its trust for code signing to **Always Trust**. `security find-identity -v -p codesigning` should list it. To use an identity you already have, set `LOOM_CODESIGN_IDENTITY` to its name.

```bash
git clone https://github.com/gencberke/loom.git
cd loom
./build.sh --check-only   # checks the tree, the signing identity and the paths; builds nothing
./build.sh                # release build, sign, verify, install to /Applications/Loom.app
```

The build goes to `~/Library/Caches/loom-release-build`; `./build.sh --target <path>.app` installs somewhere else. The install is refused while Sphyrna is running.

## Your data

Sphyrna keeps its catalog in `~/Library/Application Support/Loom` and its sockets in `~/.loom`. It reads Claude Code's own files on your Mac for state, subagents and usage, and never changes your Claude settings. Remora answers by sending short excerpts of your sessions to Claude through your own Claude Code login; its memory stays on your Mac, where you can see it and clear it. Sphyrna's logs carry ids and counts, never your prompts, titles or transcripts.

## How this repository works

Sphyrna is developed in a separate repository together with its tests, design notes and tooling; its code still carries the name Loom. Each release is exported here as one commit and one `v<version>` tag, so this tree holds only what the app is built from: the Swift sources, the terminal engine ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), vendored with local patches), the assets and `build.sh`. Codex support exists in the code but cannot be started in this version.

Found a bug or have an idea? [Open an issue](https://github.com/gencberke/loom/issues).

## License

MIT, see [LICENSE](LICENSE). SwiftTerm keeps its own MIT license in [`Vendor/SwiftTerm/LICENSE`](Vendor/SwiftTerm/LICENSE); [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists the rest.
