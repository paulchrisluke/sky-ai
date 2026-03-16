# Sparkle Setup (Outside App Store)

This project requires all three for updates to work:

1. `SPARKLE_FEED_URL` in `agent-mac/.env` (for example `https://downloads.blawby.com/appcast.xml`)
2. `SPARKLE_PUBLIC_ED_KEY` in `agent-mac/.env`
3. Reachable hosting for the feed URL and release artifacts

## 1) Configure DNS + hosting

- Create DNS record for `downloads.blawby.com` in Cloudflare.
- Point it to wherever you host release files (`appcast.xml`, `.zip`, `.dmg`, notes).
- Confirm it resolves publicly before testing Sparkle.

## 2) Generate Sparkle keypair

Run:

```bash
cd agent-mac
./scripts/sparkle-generate-keys.sh
```

This uses Sparkle's `generate_keys`, stores private key in Keychain, and writes `SPARKLE_PUBLIC_ED_KEY` to `.env`.

## 3) Build/install with Sparkle config

Run:

```bash
cd agent-mac
./dev-install.sh
```

`dev-install.sh` fails fast if `SPARKLE_FEED_URL` or `SPARKLE_PUBLIC_ED_KEY` are missing, and injects both into the generated `Info.plist` at build time.

## 4) Generate signed appcast

Put release archives (`.zip` or `.dmg`) in a directory, then run:

```bash
cd agent-mac
./scripts/sparkle-generate-appcast.sh <release-artifacts-dir>
```

Upload generated `appcast.xml` and release files to the host behind `SPARKLE_FEED_URL`.

## Notes

- Do not commit private Sparkle keys.
- `SUPublicEDKey` and `SUFeedURL` are embedded in app `Info.plist` during install/build.
- If Sparkle says host not found, DNS/hosting is still not reachable.

## GitHub Actions release automation

Workflow file:

- `.github/workflows/macos-release.yml`

Required GitHub repository secrets:

- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `SPARKLE_PRIVATE_KEY`
- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Trigger:

- Push a tag like `v1.0.2`, or run workflow manually.
