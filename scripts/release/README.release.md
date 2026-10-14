<p align="center">
  <img src="assets/readme/icon.png" width="128" height="128" alt="Loom's icon: a ram with a terminal prompt for an eye">
</p>

<h1 align="center">Loom</h1>

<p align="center">
  <b>Many Claude Code sessions. One calm window.</b><br>
  A native macOS app that runs real Claude Code terminals side by side and keeps an eye on every one of them.
</p>

<p align="center">
  <a href="https://github.com/gencberke/loom/releases/latest">Download</a> ·
  <a href="#build-it-yourself">Build it yourself</a> ·
  macOS 27 · version @VERSION@
</p>

<p align="center">
  <img src="assets/readme/window.png" alt="The Loom window: projects and sessions with their live state in the sidebar, the selected session's Claude Code terminal on the right">
</p>

## Why

You start Claude Code in a terminal tab. Then another one. Then five more. One is waiting for your approval in tab four, one finished ten minutes ago somewhere, one is still pondering. Loom gathers them in one window: a sidebar of projects and sessions with their live state, and the real terminal of the one you pick. Claude Code stays exactly as it is; Loom just keeps the flock together. 🐏

## What it does

- **Real terminals.** Every session is the real `claude` CLI in a real terminal, not a copy of its interface.
- **Live state at a glance.** <img src="assets/readme/chase.svg" width="14" height="14" alt=""> working, 🟠 needs approval, 🔴 failed, 🔵 finished and not read yet. The same signs show in the sidebar, the tabs, the Dock badge and the menu bar.
- **Projects and tabs.** Sessions sit under their project, each project with its own soft colour. Keep the ones you switch between open as tabs.
- **Resume anything.** Past sessions stay in the list, and Resume picks up the same conversation.
- **Subagents, live.** A session's subagents appear under its card; click one to read its transcript while it works.
- **Sessions that open sessions.** A session can ask Loom to start a new one for a task. Nothing starts until you approve it.
- **Usage without guesswork.** Your 5-hour and weekly plan limits, tokens per day and an estimated cost, from Claude Code's own records on your Mac.
- **Clean exits.** Each session runs in its own process scope. Quit stops everything Loom started, and nothing else.
- **Delete for real.** Deleting a session removes its local Claude Code data, and only its own.

## A look around

<p align="center">
  <img src="assets/readme/menu-bar.png" width="800" alt="Loom's menu bar menu with the sessions that need you and the ones at work, next to a notification that a session waits for approval">
</p>
<p align="center"><i>The ram in the menu bar knows who needs you, and a notification tells you when a session waits for approval while you are elsewhere.</i></p>

<p align="center">
  <img src="assets/readme/subagents.png" width="800" alt="A subagent's transcript open in place of the terminal, with Back to the session">
</p>
<p align="center"><i>Click a subagent to follow its transcript as it works; Esc takes you back to the session.</i></p>

<p align="center">
  <img src="assets/readme/usage.png" width="460" alt="Settings, Usage: plan limits, tokens of the last 7 days, tokens per day and usage by model">
</p>
<p align="center"><i>Plan limits first, then where the tokens went.</i></p>

<p align="center"><sub>The pictures are rendered from the design mock-ups Loom was built from, with made-up sample data.</sub></p>

## Install

1. Download `Loom-@VERSION@.zip` from the [latest release](https://github.com/gencberke/loom/releases/latest), unzip it and move **Loom.app** to `/Applications`.
2. Loom is signed with a personal certificate but not notarized by Apple, so macOS blocks the downloaded copy. Clear the download flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Loom.app
   ```

3. Open Loom, add a project folder and start a session.

You need macOS 27 on Apple silicon and [Claude Code](https://claude.com/claude-code) installed and signed in. Loom starts sessions with the environment of a new login shell, so `claude` has to work in a fresh Terminal window; only zsh, the macOS default, is supported as that shell for now.

## Build it yourself

You need macOS 27, Xcode with its Swift toolchain, and a code-signing identity. Loom refuses ad-hoc signing so that macOS privacy permissions survive a rebuild. A self-signed certificate is enough: in Keychain Access choose **Certificate Assistant → Create a Certificate…**, name it `Loom Dev Code Signing`, pick **Self-Signed Root** and **Code Signing**, then set its trust for code signing to **Always Trust**. `security find-identity -v -p codesigning` should list it. To use an identity you already have, set `LOOM_CODESIGN_IDENTITY` to its name.

```bash
git clone https://github.com/gencberke/loom.git
cd loom
./build.sh --check-only   # checks the tree, the signing identity and the paths; builds nothing
./build.sh                # release build, sign, verify, install to /Applications/Loom.app
```

The build goes to `~/Library/Caches/loom-release-build`; `./build.sh --target <path>.app` installs somewhere else. The install is refused while Loom is running.

## Your data

Loom keeps its catalog in `~/Library/Application Support/Loom` and its sockets in `~/.loom`. It reads Claude Code's own files on your Mac for state, subagents and usage. Loom itself has no network code, and its logs carry ids and counts, never your prompts or transcripts.

## How this repository works

Loom is developed in a separate repository together with its tests, design notes and tooling. Each release is exported here as one commit and one `v<version>` tag, so this tree holds only what the app is built from: the Swift sources, the terminal engine ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), vendored with Loom's patches), the assets and `build.sh`. Codex support exists in the code but is switched off in this build.

Found a bug or have an idea? [Open an issue](https://github.com/gencberke/loom/issues).

## License

MIT, see [LICENSE](LICENSE). SwiftTerm keeps its own MIT license in [`Vendor/SwiftTerm/LICENSE`](Vendor/SwiftTerm/LICENSE).

<p align="center"><sub>Built with a lot of Claude Code sessions, the kind Loom keeps track of.</sub></p>
