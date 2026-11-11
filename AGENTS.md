# AGENTS.md

Hark is private, on-device dictation for macOS. It is more private, more accurate and faster than the dictation built into macOS. The user presses F5 (or ⌥Space), talks, presses it again, and the text is pasted where their cursor is. Whisper runs locally through whisper.cpp inside Hark.app. This file tells an AI agent how to install Hark for a user, and how to work on this repo.

## Install Hark for a user

### 1. Check the Mac

```sh
uname -sm                     # expect: Darwin arm64
sw_vers -productVersion       # expect: 14 or later
```

### 2. Install the app

With Homebrew (`command -v brew` finds it):

```sh
brew install --cask bath/tap/hark
open /Applications/Hark.app
```

Without Homebrew:

```sh
curl -fsSL https://hark.works/install.sh | bash
```

The script downloads the disk image from the latest GitHub release, copies Hark.app to `/Applications` and opens it. If `hark.works` does not answer, use `https://raw.githubusercontent.com/bath/hark-stt/main/install.sh`.

On its first run Hark.app downloads the Whisper model (574 MB).

### 3. Fix what the doctor reports

```sh
/Applications/Hark.app/Contents/MacOS/Hark doctor --json
```

The report has `ok`, `next_step`, and `checks`. Each check has `id`, `ok`, `required`, and, when it failed, `needs_human`, `fix` and `command`. Repeat until `ok` is `true`:

1. Read `next_step`.
2. If `needs_human` is `true`, run `command`, tell the user the `fix` text, and wait until they say they are done.
3. If `needs_human` is `false`, run `command` yourself.
4. Run the doctor again. Add `--wait 60` while the model downloads, and `--wait 15` after the app starts.

The human steps you will see:

| Check | What the user does |
|---|---|
| `microphone` | Clicks Allow when macOS asks if Hark may use the microphone. |
| `accessibility` | System Settings → Privacy & Security → Accessibility → turns on Hark. Hark continues by itself. |

Checks with `"required": false` are optional: `app_in_applications`, `login_item` (start at login) and `f5_key` (F5 starts dictation; ⌥Space always works). Their commands need no person.

### 4. Hand over

When `ok` is `true`, tell the user:

- Click into any text field, press F5 (or ⌥Space), talk, and press it again. The text is pasted where the cursor is.
- The first press shows a short welcome card. Pressing F5 again closes it and starts recording.
- The 🎙 icon in the menu bar has the sound packs, the Notch Island switch and Set Up Hark….
- 🎙 → Speech Model changes from Whisper to Parakeet (NVIDIA Parakeet TDT 0.6B v2, English only, 464 MB, downloaded the first time). Parakeet is faster. The doctor checks the model the user chose.
- The last transcript stays on the clipboard, so ⌘V pastes it again.

### Do not

- Do not edit the macOS privacy database (TCC), turn off SIP, or use `sudo` for Hark. The user grants permissions in System Settings.

## Update Hark

- With Homebrew: `brew upgrade --cask hark`.
- Without Homebrew: run the install script again. It quits Hark and replaces it.
- The user can also do it in the app: 🎙 → Check for Updates…. Hark downloads the new version, replaces itself and starts again.
- Hark asks hark.works for a new version once a day, after a dictation. When there is one, the Notch Island shows "Update available. Open the menu bar icon." below "Pasted", and the 🎙 menu has Update to Hark X.Y.Z… as its first item. 🎙 → Check for Updates Automatically turns this off.

Settings, permissions and the model stay. Run the doctor afterwards.

## Remove Hark

```sh
osascript -e 'quit app id "works.hark.Hark"'
/Applications/Hark.app/Contents/MacOS/Hark login-item off
rm -rf /Applications/Hark.app
rm -rf ~/Library/Application\ Support/Hark      # the model and status; ask the user first
defaults delete works.hark.Hark                  # the settings
```

With Homebrew, `brew uninstall --zap --cask hark` does the same.

## Work on this repo

| Path | What it is |
|---|---|
| `app/` | Hark.app in Swift. A Swift package with no Xcode project. `HarkCore` has the `DictationEngine` and every rule that needs no macOS API; `HarkMac` has the Core Audio mic, whisper.cpp, Parakeet (Core ML, through FluidAudio) and paste; `HarkApp` is the menu bar app; `hark-dictate` dictates from the terminal. |
| `sounds/generate.py` | Renders the sound packs. `app/scripts/build-app.sh` runs it. Python standard library only. |
| `install.sh` | Installs Hark.app from the latest release. `docs/install.sh` is the same file, served at hark.works. Old 1.x installs run it for `hark update`, so it also removes the old Hammerspoon version. Keep the two copies the same. |
| `Casks/hark.rb` | A copy of the cask in [bath/homebrew-tap](https://github.com/bath/homebrew-tap). The tap has the live one. |
| `docs/` | The website (GitHub Pages from `main` `/docs`). `docs/appcast.xml` is the update feed the app reads; the release writes it. `docs/AGENTS.md` and `docs/llms.txt` are copies of the files at the root. |
| `demo-api/`, `proxy/` | Vercel projects for the website's live demo and analytics proxy. |

From `app/` (the first build downloads whisper.cpp, about 66 MB):

```sh
swift test                                          # engine and adapters, with fakes; never touches the mic
HARK_SLOW_TESTS=1 swift test -c release --filter WhisperSlowTests   # real whisper.cpp and model
HARK_SLOW_TESTS=1 swift test -c release --filter ParakeetSlowTests  # real Parakeet; skipped when its model is not on disk
swift run -c release hark-dictate                   # Return to start and stop; prints text and timings
swift run -c release hark-dictate --file clip.wav   # Whisper time for a 16 kHz mono WAV
swift run -c release hark-dictate --parakeet        # Parakeet, not Whisper; downloads its model (464 MB) when missing
scripts/build-app.sh                                # builds app/build/Hark.app
open build/Hark.app --args --preview                # a fake dictation: island and sounds, no mic
build/Hark.app/Contents/MacOS/Hark --render-island DIR   # each island state as a PNG
```

`build/Hark.app/Contents/MacOS/Hark doctor --json` reads `~/Library/Application Support/Hark/status.json`. The running app writes that file every 5 seconds (phase, model, permissions), because only the app itself can see its permissions. `HARK_SLOW_TESTS=1 swift test --filter RealModelDownloadTests` downloads the real model (574 MB), stops, resumes and checks it.

The terminal app needs the Microphone permission for `hark-dictate`.

Rules:

- A test must never reach the real user session. Use fakes for the mic, paste, `hidutil` and anything else that changes system state.
- Every failed doctor check needs a `fix` an agent can act on, and `needs_human` must be true only when a person has to act.

## Release

A merge to `main` that changes what goes into Hark.app (`app/Sources`, `app/Resources`, `app/Package.swift`, `app/dmg`, `app/scripts/build-app.sh`, `sounds`) releases it. The "Release Hark.app" workflow takes the next patch version, commits it and tags it, builds, signs and notarizes the disk image, publishes the release, and commits the cask here and in bath/homebrew-tap. Its header lists the secrets.

- For a minor or major version, set a higher `harkVersion` in `app/Sources/HarkCore/Version.swift` and merge it. The workflow uses that version as it is.
- To release the next patch with no change, run the workflow by hand from the Actions tab.
- A run that fails before it publishes deletes its draft release and its tag.

By hand, from a Mac with the Developer ID certificate:

1. Set `harkVersion` and merge to `main`.
2. Tag `vX.Y.Z` on `main` (`git tag -a vX.Y.Z -m "Hark X.Y.Z"`), push it, and make a **draft** release (`gh release create vX.Y.Z --verify-tag --draft`).
3. `HARK_SIGN_IDENTITY="Developer ID Application: …" HARK_NOTARY_PROFILE=hark app/scripts/release.sh --upload`. `--dry-run` does everything but notarization.
4. Publish the release (`gh release edit vX.Y.Z --draft=false --latest`). The install script finds the release by its `Hark-X.Y.Z.dmg` asset, and `docs/appcast.xml` links to it, so publish only after the upload.
5. Commit `Casks/hark.rb` and `docs/appcast.xml`, which `--upload` changed. It also changed the cask in bath/homebrew-tap.

The app updates itself with [Sparkle](https://sparkle-project.org). `docs/appcast.xml` (served at hark.works) names the latest disk image and has its EdDSA signature. `SUPublicEDKey` in `app/Resources/Info.plist` is the public half of the key; the private half is the `SPARKLE_PRIVATE_KEY` secret, or the login keychain for a release by hand. To make the key once: `app/.build/artifacts/sparkle/Sparkle/bin/generate_keys` prints the public key, and `generate_keys -x FILE` exports the private key. Do not change the key: installed apps accept only updates signed with it.

## Agent skills

### Issue tracker

GitHub Issues on `bath/hark-stt`, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root, made when needed. See `docs/agents/domain.md`.
