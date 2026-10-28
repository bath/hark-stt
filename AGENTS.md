# AGENTS.md

Hark is private, on-device dictation for macOS. The user presses F5 (or ⌥Space), talks, presses it again, and the text is pasted where their cursor is. Whisper runs locally through whisper.cpp. This file tells an AI agent how to install Hark for a user, and how to work on this repo.

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
curl -fsSL https://raw.githubusercontent.com/bath/hark-stt/main/install.sh | bash -s -- --json
```

With `--no-karabiner` for ⌥Space only:

```sh
curl -fsSL https://raw.githubusercontent.com/bath/hark-stt/main/install.sh | bash -s -- --json --no-karabiner
```

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

### Remove Hark

```sh
~/.hammerspoon/hark/bin/hark uninstall          # shows what it removes
~/.hammerspoon/hark/bin/hark uninstall --yes    # removes it
```

This keeps the Homebrew apps and the model. The command prints how to remove those too.

## Work on this repo

| Path | What it is |
|---|---|
| `hark.lua` | The Hammerspoon module. Installed as `~/.hammerspoon/hark/init.lua`. |
| `recorder/HarkRecorder.swift` | Native Core Audio helper. Talks JSON lines over stdin and stdout. |
| `bin/hark` | The CLI: `doctor`, `open-settings`, `uninstall`, `version`. Python standard library only. |
| `sounds/generate.py` | Renders the sound packs at install time. Python standard library only. |
| `install.sh` | The installer. Must keep working when piped from curl. |
| `karabiner/hark.json` | The F5 → F18 rule. |
| `docs/` | The website (GitHub Pages) and the README images. |

Tests:

```sh
bash tests/install-streaming.sh   # installer, with Homebrew, curl and launchctl mocked
bash tests/hark-cli.sh            # doctor report shape, uninstall safety
```

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
