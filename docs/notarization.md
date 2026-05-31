# macOS code signing + notarization

The release pipeline can produce **signed and notarized** DMGs so users
don't see "this app is from an unidentified developer / can't be opened"
Gatekeeper warnings on first launch. Without these secrets configured,
DMGs ship unsigned and users have to right-click → Open → Open Anyway.

The `scripts/notarize-dmg.sh` script is a no-op when secrets are missing
— release builds keep succeeding either way.

## One-time setup (you do this once per repo)

### 1. Apple Developer ID Application certificate

You need a **Developer ID Application** cert (not "Apple Distribution" or
"Mac App Distribution" — those are for the App Store, not standalone
distribution).

1. Go to <https://developer.apple.com/account/resources/certificates/list>.
2. Click the **+** to add a new certificate.
3. Pick **Developer ID Application** under Software.
4. Follow the prompts — you'll create a CSR in Keychain Access
   (Keychain Access menu → Certificate Assistant → Request a Certificate
   from a Certificate Authority, save it to disk, upload the CSR file).
5. Download the resulting `.cer` file, double-click to install it into
   your Keychain.

### 2. Export the cert as a `.p12`

In Keychain Access:

1. Find **Developer ID Application: \<Your Name\> (\<10-CHAR-TEAM-ID\>)**
   in the **My Certificates** category. Expand it — it should have a
   private key under it.
2. Right-click → **Export "Developer ID Application: …"**.
3. Save as `.p12`. **Set a strong password** when prompted — you'll
   put this password in a GitHub secret.

### 3. Base64-encode the `.p12`

```sh
base64 -i developer-id.p12 | pbcopy
```

That copies the base64 string to your clipboard. Don't lose it.

### 4. Get your Team ID

It's the 10-char string after your name in the cert (e.g. `ABCD123456`).
Or look it up at
<https://developer.apple.com/account/#!/membership> → Membership Details
→ Team ID.

### 5. App-specific password

`notarytool` uses an app-specific password, NOT your Apple ID password.

1. Sign in at <https://account.apple.com>.
2. Sign-In and Security → App-Specific Passwords → **Generate Password**.
3. Label it `mnml notarization` (or similar). Copy the generated password.

### 6. Add the secrets to each GitHub repo

For each of `chris-mclennan/mnml`, `chris-mclennan/mixr`,
`chris-mclennan/tmnl` — go to **Settings → Secrets and variables →
Actions → New repository secret**.

Add these 5 secrets:

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | Your 10-char team ID |
| `APPLE_DEVELOPER_ID_CERT_BASE64` | The base64 string from step 3 |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | The password from step 2 |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APP_PASSWORD` | The app-specific password from step 5 |

Or via `gh` CLI (paste-friendly):

```sh
gh secret set APPLE_TEAM_ID --repo chris-mclennan/mnml
gh secret set APPLE_DEVELOPER_ID_CERT_BASE64 --repo chris-mclennan/mnml
gh secret set APPLE_DEVELOPER_ID_CERT_PASSWORD --repo chris-mclennan/mnml
gh secret set APPLE_ID --repo chris-mclennan/mnml
gh secret set APPLE_APP_PASSWORD --repo chris-mclennan/mnml
```

Repeat for `mixr` and `tmnl`.

### 7. Trigger a release

Tag a fresh release (e.g. `v0.1.5`). The `Build macOS DMG` step will
detect the secrets, sign the `.app` inside the DMG, submit to Apple's
notary service (takes 1-5 minutes per arch), staple the ticket, and
ship the trusted DMG.

If the secrets are missing, the script logs `[notarize] … skipping
(DMG ships unsigned)` and the build continues with unsigned artifacts.

## Verifying a signed/notarized DMG locally

```sh
# Download a release DMG, then:
spctl -a -t open --context context:primary-signature \
    -v "Downloads/mnml-rs-aarch64-apple-darwin.dmg"
# Expect: "Downloads/mnml-rs-aarch64-apple-darwin.dmg: accepted"

# And check the staple:
xcrun stapler validate "Downloads/mnml-rs-aarch64-apple-darwin.dmg"
# Expect: "The validate action worked!"
```

## Cost reminder

- Apple Developer Program membership: **$99/year** (you have this).
- Notarization itself is free; rate-limited but you'll never hit it at
  release cadence.

## Troubleshooting

**`security: SecKeychainItemImport: One or more parameters passed to a function were not valid.`** — the
base64 is malformed. Re-export the `.p12` and re-encode (use `base64 -i`,
not piping a binary through pbcopy on macOS).

**`Notarization failed.` with `Invalid Status`** — most often a signature
issue. Run `codesign -dv --verbose=4 path/to/Mnml.app` locally to inspect
the signature, look for `Authority=Developer ID Application: …`.

**Notarization takes >10 minutes** — Apple's queue. Usually 1-5 minutes
but can stretch. The `--wait` flag blocks until completion or timeout.

**Want to revoke or rotate a key?** Delete the `.p12` from your Keychain,
revoke the cert at developer.apple.com → Certificates, then redo steps
1-3 with a fresh cert. Update the GitHub secret.
