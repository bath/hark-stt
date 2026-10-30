# AGENTS.md

Hark is better, private, on-device dictation for macOS. It is more private, more accurate and faster than the dictation built into macOS. The user presses F5 (or ⌥Space), talks, presses it again, and the text is pasted where their cursor is. Whisper runs locally through whisper.cpp. This file tells an AI agent how to install Hark for a user, and how to work on this repo.

## Install Hark for a user

Follow these steps in order. Each step says what you run and what the user must do. The user only has to act where macOS requires a person: permissions, a password, and one switch in Karabiner.

### 1. Check the Mac

Hark needs macOS on Apple silicon, Homebrew and the Apple Command Line Tools.

```sh
uname -sm                       # expect: Darwin arm64
command -v brew                 # expect a path, usually /opt/homebrew/bin/brew
xcrun --find swiftc             # expect a path
```

- If Homebrew is missing, ask the user to install it from https://brew.sh. Its installer asks for their password, so they must run it in their own terminal.
- If `xcrun` fails, run `xcode-select --install` and ask the user to finish the dialog that opens.

### 2. Ask one question

Ask the user: "Do you want to start dictation with the F5 key, or is ⌥Space enough?"

- F5 needs Karabiner-Elements. It installs a keyboard driver, so Homebrew may ask for the user's password, and macOS asks the user to approve the driver.
- ⌥Space needs nothing extra. Add `--no-karabiner` to the install command.

### 3. Run the installer

```sh
curl -fsSL https://hark.works/install.sh | bash -s -- --json
```

Or, if the user wants Homebrew to manage Hark:

```sh
brew install bath/tap/hark
hark setup --json             # add --no-karabiner for ⌥Space only
```

With `--no-karabiner` for ⌥Space only:

```sh
curl -fsSL https://hark.works/install.sh | bash -s -- --json --no-karabiner
```

- If `hark.works` does not answer, or `curl -fsSL https://hark.works/install.sh | head -2` does not print `#!/usr/bin/env bash` and `# Hark installer.`, use the same file from GitHub: `https://raw.githubusercontent.com/bath/hark-stt/main/install.sh`.
- It takes a few minutes the first time. Most of the time is the 550 MB model download.
- With `--json`, progress goes to stderr and stdout carries only the doctor report (see step 4).
- If your shell cannot answer a password prompt and the Karabiner step stops, ask the user to run `brew install --cask karabiner-elements` in their own terminal, then run the installer again.
- Running the installer again is safe. It also moves an old `whisper-dictation` install to the Hark names.

### 4. Fix what the doctor reports

```sh
~/.hammerspoon/hark/bin/hark doctor --json
```

The report looks like this (shortened):

```json
{
  "ok": false,
  "ready_to_dictate": false,
  "next_step": {
    "id": "accessibility",
    "title": "Hammerspoon has Accessibility permission (to paste)",
    "ok": false,
    "required": true,
    "needs_human": true,
    "fix": "Ask the user to turn on Hammerspoon in System Settings → Privacy & Security → Accessibility.",
    "command": "~/.hammerspoon/hark/bin/hark open-settings accessibility"
  },
  "checks": [ ... every check, each with ok, required and (when failed) fix ... ]
}
```

Repeat until `ok` is `true`:

1. Read `next_step`.
2. If `needs_human` is `true`, run `command` (it opens the right System Settings pane or app), tell the user the `fix` text, and wait until they say they are done.
3. If `needs_human` is `false`, run `command` yourself.
4. Run `hark doctor --json` again. Use `--wait 15` after a restart, because Hammerspoon and the model need a few seconds to load.

Checks with `"required": false` are only for the F5 key (`karabiner_app`, `karabiner_rule`). Skip them if the user chose ⌥Space.

The human steps you will usually see:

| Check | What the user does |
|---|---|
| `microphone` | System Settings → Privacy & Security → Microphone → turn on Hammerspoon. If Hammerspoon is not listed, they press ⌥Space once so macOS asks. |
| `accessibility` | System Settings → Privacy & Security → Accessibility → turn on Hammerspoon. |
| `karabiner_rule` | Approve Karabiner's driver and Input Monitoring, then Karabiner-Elements → Settings → Complex Modifications → Add rule → turn on "F5 / Dictation key → F18". |

Optional: `hark open-settings dictation` opens Keyboard settings, where the user can turn off Apple Dictation so it does not also start on F5.

### 5. Hand over

When `ok` is `true`, tell the user:

- Click into any text field, press F5 (or ⌥Space), talk, and press it again. The text is pasted where the cursor is.
- The first press shows a short welcome card. Pressing F5 again closes it and starts recording.
- The 🎙 icon in the menu bar has the sound packs, the Notch Island switch and a preview.
- The last transcript stays on the clipboard, so ⌘V pastes it again.

### Do not

- Do not edit the macOS privacy database (TCC), turn off SIP, or use `sudo` for Hark. The user grants permissions in System Settings.
- Do not change `~/.hammerspoon/init.lua` beyond the `require("hark")` line the installer adds. The user may have their own config in it.

## Update Hark

Do this when the user asks you to update or upgrade Hark.

1. Find the `hark` CLI. Use `hark` if `command -v hark` finds it (a Homebrew install). If not, use `~/.hammerspoon/hark/bin/hark`. If neither exists, Hark is not installed. Follow "Install Hark for a user".
2. Run:

   ```sh
   hark update --json
   ```

   - For a Homebrew install, this runs `brew upgrade hark` and then `hark setup`. For a curl install, it runs the latest installer from hark.works.
   - It keeps the user's choice of F5 or ⌥Space.
   - If the output says `update` is an unknown command, the install is 1.0.0. Run the installer again (step 3 of the install) to update it. If `~/.config/karabiner/assets/complex_modifications/hark.json` does not exist, add `--no-karabiner`.
3. The output ends with the doctor report. Fix what it reports, the same as in step 4 of the install. An update keeps the macOS permissions, so you usually do not have to ask the user for anything.
4. Tell the user the new version (`hark version`).

From version 1.2.0, the user can also update without you: 🎙 menu → Check for Updates….

If you run `brew upgrade hark` yourself, run `hark setup --json` after it. `brew upgrade` changes only the files in Homebrew. The `hark_current` doctor check fails until `hark setup` copies the new files to `~/.hammerspoon/hark`.

## Remove Hark

```sh
~/.hammerspoon/hark/bin/hark uninstall          # shows what it removes
~/.hammerspoon/hark/bin/hark uninstall --yes    # removes it
```

This keeps the Homebrew apps and the model. The command prints how to remove those too. For a Homebrew install, also run `brew uninstall hark`.

## Work on this repo

| Path | What it is |
|---|---|
| `hark.lua` | The Hammerspoon module. Installed as `~/.hammerspoon/hark/init.lua`. |
| `recorder/HarkRecorder.swift` | Native Core Audio helper. Talks JSON lines over stdin and stdout. |
| `bin/hark` | The CLI: `doctor`, `update`, `setup`, `open-settings`, `uninstall`, `version`. Python standard library only. |
| `Formula/hark.rb` | A copy of the Homebrew formula in [bath/homebrew-tap](https://github.com/bath/homebrew-tap). The tap has the live one. |
| `sounds/generate.py` | Renders the sound packs at install time. Python standard library only. |
| `install.sh` | The installer. Must keep working when piped from curl. |
| `karabiner/hark.json` | The F5 → F18 rule. |
| `docs/` | The website (GitHub Pages) and the README images. |
| `app/` | The native Hark.app in Swift (issue #30), being built. A Swift package with no Xcode project. `HarkCore` has the `DictationEngine` and every rule that needs no macOS API; `HarkMac` has the Core Audio mic, whisper.cpp and paste; `hark-dictate` dictates from the terminal. |

Tests:

```sh
bash tests/install-streaming.sh   # installer, with Homebrew, curl and launchctl mocked
bash tests/hark-cli.sh            # doctor report shape, uninstall safety
```

The Swift package (from `app/`; the first build downloads whisper.cpp, about 66 MB):

```sh
swift test                                          # engine and adapters, with fakes; never touches the mic
HARK_SLOW_TESTS=1 swift test -c release --filter WhisperSlowTests   # real whisper.cpp and model
swift run -c release hark-dictate                   # Return to start and stop; prints text and timings
swift run -c release hark-dictate --file clip.wav   # Whisper time for a 16 kHz mono WAV
scripts/build-app.sh                                # builds app/build/Hark.app
```

Hark.app writes `~/Library/Application Support/Hark/status.json` every 5 seconds (phase, model, permissions). Its hotkeys work next to the Hammerspoon version's, so both start on ⌥Space: quit one of them when you test the other.

The terminal app needs the Microphone permission for `hark-dictate`.

The Lua tests run inside Hammerspoon with a fake `hs`, so they do not touch the live setup. Run them one at a time:

```sh
hs -c "dofile('$PWD/tests/cold-microphone-hot-path.lua')"
hs -c "dofile('$PWD/tests/server-recovery.lua')"
hs -c "dofile('$PWD/tests/notch-island-sounds.lua')"
hs -c "dofile('$PWD/tests/onboarding.lua')"
```

If `hs -c` starts to print `ipc port is no longer valid` or `stack overflow`, restart Hammerspoon (`killall Hammerspoon; open -a Hammerspoon`), wait a few seconds, and try again. That is the IPC client, not the code under test.

Rules:

- A test must never reach the real user session. Mock `launchctl`, `lsof` and anything else that changes system state.
- Keep `VERSION` in `hark.lua` and `bin/hark` the same. `tests/hark-cli.sh` checks this.
- Every failed doctor check needs a `fix` an agent can act on, and `needs_human` must be true only when a person has to act.

Release:

1. Set the new `VERSION` in `hark.lua` and `bin/hark`, and merge to `main`.
2. Tag `vX.Y.Z` on `main` and make a GitHub release from the tag (`gh release create vX.Y.Z --verify-tag`). The 🎙 menu reads `releases/latest`, so a tag without a release is not offered.
3. In [bath/homebrew-tap](https://github.com/bath/homebrew-tap), set the formula's `url` to the new tag and its `sha256` to the hash of that tarball. Run `brew audit --strict bath/tap/hark`. Copy the formula to `Formula/hark.rb` here.

## Agent skills

### Issue tracker

GitHub Issues on `bath/hark-stt`, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root, made when needed. See `docs/agents/domain.md`.
