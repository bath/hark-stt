<h1 align="center">whisper-dictation</h1>

<p align="center">
  Press F5, talk, press F5 again. Your words are typed into whatever app you are in.<br>
  Whisper runs on your Mac. No cloud, no account, no telemetry.
</p>

<p align="center">
  <img alt="macOS on Apple silicon" src="https://img.shields.io/badge/macOS-Apple%20silicon-000000?logo=apple&logoColor=white">
  <img alt="Runs offline" src="https://img.shields.io/badge/runs-offline-2ea44f">
  <img alt="Model: Whisper large-v3-turbo" src="https://img.shields.io/badge/model-Whisper%20large--v3--turbo-6b3fd4">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <img src="docs/notch-island.gif" width="720" alt="The MacBook notch grows into a black pill with a red recording dot, a timer and voice bars, then shows Transcribing with a spinner, then a green check and Pasted">
</p>

```sh
curl -fsSL https://raw.githubusercontent.com/bath/whisper-dictation/main/install.sh | bash
```

## What you get

- **Dictation in any text field.** Mail, Slack, your editor, a browser form. The text is pasted where your cursor is.
- **Whisper large-v3-turbo on your own machine.** [whisper.cpp](https://github.com/ggerganov/whisper.cpp) keeps the model loaded in a local server, so there is no startup wait per dictation.
- **Nothing leaves the Mac.** The only network traffic is to `127.0.0.1`. The installer downloads the model once from Hugging Face.
- **The mic is off until you press F5.** A small native helper keeps the audio input ready but stopped, and releases the mic as soon as you stop talking. The orange mic dot in the menu bar shows only during a take.
- **Notch Island.** The MacBook notch grows into a black pill while you talk. It shows a red dot, a timer and voice bars that follow your voice. Then it shows "Transcribing", then a green check and "Pasted". On a screen with no notch, the pill drops from the top center. It opens on the screen that has your mouse pointer.
- **Sounds for each step.** 26 sound packs, each with a sound for start, stop, pasted and error. Pick one, or turn sounds off, in the 🎙 menu.
- **Your last transcript stays on the clipboard.** If the paste landed in the wrong place, press ⌘V.

## Install

You need [Homebrew](https://brew.sh) and the Apple Command Line Tools (`xcode-select --install`).

```sh
curl -fsSL https://raw.githubusercontent.com/bath/whisper-dictation/main/install.sh | bash
```

The installer:

1. Installs `whisper-cpp`, [Hammerspoon](https://www.hammerspoon.org) and [Karabiner-Elements](https://karabiner-elements.pqrs.org) with Homebrew.
2. Downloads the Whisper model (about 550 MB) to `~/.cache/whisper`.
3. Builds the native recorder helper and the sound library.
4. Starts `whisper-server` as a launchd agent, so it stays up across crashes and reboots.
5. Copies the Hammerspoon module and the Karabiner rule into place.

To read the script first, clone the repo and run it locally:

```sh
git clone https://github.com/bath/whisper-dictation
cd whisper-dictation
./install.sh
```

### Three clicks macOS does not let a script do

1. **System Settings → Privacy & Security.** Turn on Hammerspoon under Microphone and under Accessibility.
2. **Karabiner-Elements** (the installer opens it). Approve its driver and Input Monitoring. Then go to Settings → Complex Modifications → Add rule, and turn on "F5 / Dictation key → F18". Installing the rule file does not turn it on.
3. *Optional.* System Settings → Keyboard → Dictation → Off, so Apple's dictation does not also start on that key.

`⌥Space` also toggles dictation. That shortcut needs only step 1, so you can skip Karabiner if you do not use the F5 key. Karabiner is there only because macOS sends the dictation key as a special event that Hammerspoon cannot catch.

## Use it

Wait for the menu-bar icon to change from ⏳ to 🎙. Click into any text field, press **F5**, talk, and press **F5** again. The text is pasted shortly after you stop.

The first press after you install or update shows a short welcome card. Press F5 again, or click "Start dictating", to start your first take.

<p align="center">
  <img src="docs/welcome.png" width="380" alt="Welcome card: F5 to talk, F5 again to stop. Text lands wherever your cursor is. Your last transcript stays on the clipboard. A short sound on start, stop and paste. Everything stays on your Mac.">
</p>

### The 🎙 menu

| Item | What it does |
|---|---|
| Notch Island | Turns the animation on or off. |
| Sound | Picks a sound pack, sets the volume, or turns sounds off. Picking a pack plays it. |
| Preview animation and sounds | Plays a fake 3-second dictation. Nothing is recorded or pasted. |
| Show welcome screen | Shows the welcome card again. |

### Sound packs

`sounds/generate.py` makes 23 packs at install time with only the Python standard library. Three more packs use the sounds that ship with macOS.

| Pack | Sound |
|---|---|
| Pop (default) | Round bubble pops that bend up to start and down to stop. |
| Soft Bell | A clear bell to start, a lower bell to stop, a small chime when the text lands. |
| Pluck | Two plucked string notes, up to start and down to stop. |
| Whoosh | Soft air that rises to start and falls to stop. |
| Shimmer | A fast four-note arpeggio with a light echo. |
| Tape Deck | The clunk of a record button. |
| Power Up | A short retro synth rise and fall. |
| Sonar | A ping with a long echo. |
| Marimba | Wooden mallet notes. |
| Glass | Small tinkles, like tapping a wine glass. |
| Droplet | Water drops. |
| Typewriter | A key strike, the carriage, and the bell when the text lands. |
| Kalimba | Thumb-piano notes. |
| Blip | Tiny pure tones. The most neutral choice. |
| Wood Block | Hollow wooden knocks. |
| Harp | A quick harp sweep. |
| Cosmic | Sci-fi sweeps with a little wobble. |
| Electric Piano | Soft rolled chords. |
| Arcade | 8-bit chiptune. The pasted sound is a coin. |
| Soft Thump | Low thumps you feel more than hear. |
| Chirp | Quick bird-like chirps. |
| Singing Bowl | A calm bowl with a long ring. |
| Faint Click | A faint tick at each step. |
| macOS Classic, Bright, Deep | Built-in Mac sounds such as Tink, Pop, Glass and Hero. |

## How it works

```mermaid
flowchart LR
  F5[F5 key] -->|Karabiner| F18[F18]
  F18 -->|Hammerspoon hotkey| HS[whisper-dictation.lua]
  HS -->|START / STOP on stdin| REC[whisper-recorder<br>native Core Audio helper]
  REC -->|mic levels, WAV path| HS
  HS -->|POST WAV to 127.0.0.1:8178| SRV[whisper-server<br>launchd agent, model loaded]
  SRV -->|text| HS
  HS -->|clipboard + ⌘V| APP[Your app]
  HS --> UI[Notch Island<br>and sounds]
```

1. When Hammerspoon loads, the native helper prepares a stopped Core Audio input unit, and launchd keeps `whisper-server` running with the model in memory.
2. F5 starts the input unit. The helper sends mic levels about 30 times a second, and the island uses them to draw the voice bars.
3. The second F5 stops the input unit and releases the mic. The helper writes a temporary WAV file.
4. Hammerspoon sends the WAV to the local server, puts the text on the clipboard, and presses ⌘V.

The Hammerspoon module never starts the server itself. It polls `/health`, reconnects when launchd brings the server back, and shows ⏳ while it waits.

## Customize

Edit the config block at the top of `~/.hammerspoon/whisper-dictation.lua`, then reload Hammerspoon from the 🎙 menu.

| Setting | Default | Notes |
|---|---|---|
| `MIC` | `nil` | `nil` uses the Mac's built-in mic. Set an exact device name such as `":Studio Display Microphone"` to use another one. |
| `LANG` | `"en"` | Or `"auto"`. |
| `HOTKEYS` | `{{}, "f18"}`, `{{"alt"}, "space"}` | Add or replace toggle hotkeys. |

To change the Whisper model or other server flags, edit `~/Library/LaunchAgents/com.whisper-dictation.server.plist` and restart the agent with `launchctl kickstart -k gui/$(id -u)/com.whisper-dictation.server`. Or run `install.sh` again.

## FAQ

**How is this different from Apple Dictation?** It uses Whisper large-v3-turbo, works with the same key in every app, and never needs a network connection after install. You can turn Apple Dictation off (step 3 above) so the two do not conflict.

**Does it type while I talk?** No. Whisper gets the whole take after you stop, so the text arrives in one paste.

**Can I use another model?** Yes. Download any whisper.cpp `ggml` model and point the LaunchAgent's `-m` flag at it. Smaller models are faster and less accurate.

**Will the start sound end up in my transcript?** The start sound plays while the mic opens, so the mic can hear it. The start sounds are short (Pop is 140 ms) for this reason. If you see it in your text, pick a quieter pack or turn sounds off.

**Intel Mac?** The paths assume Apple-silicon Homebrew (`/opt/homebrew`). On Intel, change them to `/usr/local`.

## Troubleshooting

- **F5 asks whether you want to turn on Apple's Dictation.** The Karabiner rule is installed but not turned on. In Karabiner-Elements, open Complex Modifications → Add rule and turn on "F5 / Dictation key → F18".
- **F5 does nothing.** Try `⌥Space`. If that works, check the Karabiner rule and its Input Monitoring permission. If it does not, turn on Hammerspoon under Microphone and Accessibility, then reload its config from the menu-bar icon.
- **The first F5 press shows a Microphone prompt.** Approve it, wait for 🎙, then press F5 again. macOS can wait to show this prompt until the helper first starts the input hardware.
- **How to check the hotkey.** The menu-bar icon changes from 🎙 to 🔴 while you record.
- **The menu stays at ⏳.** The recorder or the Whisper server did not start. Recorder errors are in the Hammerspoon Console, and server errors are in `/tmp/whisper-server.log`. launchd restarts the server, and dictation reconnects without a reload.
- **No sounds.** Check the volume in the Sound menu. If the menu says "No sounds installed", run `install.sh` again.

## Limits

- Text arrives after you stop, not word by word.
- The helper keeps its input unit initialized but stopped. On the tested M1 Pro, the first audio buffer arrived 64 ms after F5 (median, 71 ms p95). Other Macs and external microphones vary.
- A mic that is fully off cannot record before F5. Anything you say during the short start-up window after the key press is lost. In normal use, that window was shorter than the time it takes to start speaking.
- The helper picks the built-in mic by name, so an iPhone Continuity mic cannot take over because it appears first in the device list.
- A few secure fields block programmatic paste. The transcript is still on the clipboard.

## Development

The tests run inside Hammerspoon with a fake `hs` object, so they do not touch your live setup. Run each one from the Hammerspoon Console:

```lua
dofile("/path/to/whisper-dictation/tests/cold-microphone-hot-path.lua")
dofile("/path/to/whisper-dictation/tests/server-recovery.lua")
dofile("/path/to/whisper-dictation/tests/notch-island-sounds.lua")
dofile("/path/to/whisper-dictation/tests/onboarding.lua")
```

The installer test runs in a shell with mocked Homebrew, curl and launchctl:

```sh
bash tests/install-streaming.sh
```

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.whisper-dictation.server
rm ~/Library/LaunchAgents/com.whisper-dictation.server.plist
rm ~/.hammerspoon/whisper-dictation.lua
rm ~/.hammerspoon/WhisperRecorder.swift
rm ~/.hammerspoon/bin/whisper-recorder
rm -r ~/.hammerspoon/whisper-sounds ~/.hammerspoon/whisper-sounds-generate.py
rm ~/.config/karabiner/assets/complex_modifications/whisper-dictation.json
# Remove the require("whisper-dictation") line from ~/.hammerspoon/init.lua.
# Turn off the rule in Karabiner. Run `brew uninstall --cask hammerspoon karabiner-elements` if nothing else uses them.
```

## License

MIT. See [LICENSE](LICENSE).
