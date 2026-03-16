# Mac App Setup (Skyler/Test User)

This is the current install flow for the native macOS app (`BlawbyAgent.app`).
The old `install.sh`/launch-agent flow is no longer the primary path.

## 1) Install app bundle

1. Download the latest app zip:
   - `https://downloads.blawby.com/BlawbyAgent-1.0+2.zip` (or newer)
2. Unzip.
3. Move `BlawbyAgent.app` into `/Applications`.
4. Launch once from Finder.

## 2) First-run trust (non-Developer-ID test setup)

If macOS blocks launch:

1. In Finder, right-click `BlawbyAgent.app` and choose `Open`.
2. If still blocked, run:

```bash
xattr -dr com.apple.quarantine /Applications/BlawbyAgent.app
```

Then launch again.

## 3) Configure inside app

1. Open menu bar app.
2. Open `Preferences`.
3. Set worker URL + API key.
4. Grant requested Mail/Calendar/Contacts permissions.

## 4) Verify healthy runtime

1. Open `Dashboard` from menu bar.
2. Confirm sources appear and sync counters move.
3. Confirm no red startup/runtime errors in UI.

## 5) Updates (Sparkle)

1. From app menu, run `Check for Updates…`.
2. Feed URL is:
   - `https://downloads.blawby.com/appcast.xml`

For test users, this works without App Store, but Gatekeeper prompts can still occur because builds are not Developer-ID notarized yet.

## Developer notes (local)

- Local deterministic install:

```bash
./agent-mac/dev-install.sh
```

- Sparkle release publishing scripts:
  - `scripts/macos-app.sh release`
  - `scripts/macos-app.sh appcast`
  - `agent-mac/scripts/sparkle-generate-appcast.sh`

## Legacy note

`agent-mac/install.sh` and `agent-mac/uninstall.sh` are legacy and should not be used for the current Skyler/test-user path.
