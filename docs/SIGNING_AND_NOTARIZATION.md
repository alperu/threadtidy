# Signing & Notarization

How to produce a `ThreadTidy.zip` that opens cleanly on any Mac with
no Gatekeeper warnings or right-click workarounds.

The pipeline is fully wrapped in `script/build-app.sh --notarize`. The
sections below cover the **one-time setup** you do per machine, then
the **per-build flow** that's just one command after that. For hands-off
releases, the **GitHub Actions** section at the end does all of this in
CI when you push a version tag.

> The build script no longer hardcodes any signing identity. You must
> export `SIGN_IDENTITY` (locally) or set it as a repository secret (in
> CI) before signing — see below.

---

## Why this is needed

`script/build-app.sh` (without `--notarize`) ad-hoc signs the app. That
works on the Mac that built it, but other Macs see one of:

- "ThreadTidy.app cannot be opened because Apple cannot check it
  for malicious software"
- "ThreadTidy.app is damaged and can't be opened"
- "The application cannot be opened because the developer cannot be
  verified"

A Developer ID signature plus an Apple-issued **notarization ticket**
stapled to the bundle clears all three messages. Notarization is
mandatory for distribution outside the Mac App Store on macOS 10.15+.

---

## One-time setup

### 1. Apple Developer account

You need a paid **Apple Developer Program** membership ($99/year). A
free Apple ID won't issue Developer ID certificates.

### 2. Developer ID Application certificate

Easiest path is via Xcode:

1. **Xcode → Settings → Accounts**.
2. Click **+** → **Apple ID** → sign in.
3. Select your account → **Manage Certificates…** → **+** →
   **Developer ID Application**.
4. Close the dialog.

Or via the developer portal — see Apple's docs at
<https://developer.apple.com/help/account/create-certificates/>.

Verify the cert installed:

```sh
security find-identity -v -p codesigning
```

You should see a line like:

```
1) <40-HEX-FINGERPRINT> "Developer ID Application: Your Name (TEAMID)"
   1 valid identities found
```

The string in quotes is your **signing identity**; the parenthetical
`(TEAMID)` is your **Team ID**. Export the full quoted string as
`SIGN_IDENTITY` before building (the script has no default):

```sh
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

### 3. App-specific password

Apple's notary service authenticates uploads via either an
**App-Specific Password** or an **App Store Connect API key**. The
password is simpler and equally secure for a single developer.

1. Go to <https://appleid.apple.com> → **Sign-In and Security** →
   **App-Specific Passwords**.
2. Click **+**, name it (e.g. `ThreadTidy Notary`), copy the
   four-group password (`abcd-efgh-ijkl-mnop`).
3. Store it in macOS Keychain via `notarytool`:

```sh
xcrun notarytool store-credentials "ThreadTidy-notary" \
    --apple-id "your-apple-id@example.com" \
    --team-id "<YOUR_TEAM_ID>" \
    --password "abcd-efgh-ijkl-mnop"
```

You should see `Profile "ThreadTidy-notary" saved.` The password
now lives in Keychain and is referenced by the profile name — it
never appears in shell history, env vars, or the build script. The
script defaults to that profile name; override with `NOTARY_PROFILE=...`
to use a different one.

---

## Per-build flow

Once setup is done:

```sh
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./script/build-app.sh --notarize
```

`--notarize` requires `SIGN_IDENTITY` to be set; the script exits with a
clear error if it's empty. This does, in order:

1. Bump build number, stamp `CFBundleVersion` into `Info.plist`.
2. Generate `AppIcon.icns` if missing.
3. Build the binary via SwiftPM (`swift build -c release --product ThreadTidy`).
4. Assemble `Contents/{MacOS,Resources,Frameworks}` and patch the
   binary's `@rpath` to find the bundled PDFium dylib.
5. **Sign `libpdfium.dylib`** (and any inner bundles/metallibs) with
   Developer ID + hardened runtime + secure timestamp. Inner binaries
   must be signed BEFORE the outer bundle.
6. **Sign the .app** with Developer ID + hardened runtime + secure
   timestamp. Library validation passes because we re-signed PDFium
   with the same team.
7. Verify the signature locally with `codesign --verify --strict`.
8. Zip the bundle with `ditto -c -k --keepParent` (Apple's recommended
   bundler — preserves resource forks/symlinks; vanilla `zip` mangles
   them).
9. **Submit to Apple's notary service** with `xcrun notarytool submit
   --wait`. Apple's checks usually take 1–5 minutes. The script blocks
   until status is `Accepted`.
10. **Staple the ticket** onto the .app with `xcrun stapler staple`.
    Stapled apps validate offline — recipients don't need a working
    internet connection on first launch.
11. Re-zip the stapled bundle as `build/ThreadTidy.zip`.

Final output:

```
Notarized + stapled. Recipients can double-click the app from the
unzipped folder with no warnings, even on a fresh Mac with no
developer tools.
```

The first time you build after a fresh login, macOS will prompt for
your **Mac login password** so `codesign` can read the cert's private
key from Keychain. Click **Always Allow** to skip the prompt on
future builds.

---

## Automated signed releases (GitHub Actions)

Push a version tag and let CI do the whole signed + notarized build for
you. The workflow lives at `.github/workflows/release.yml` and triggers
on any tag matching `v*` (and on manual `workflow_dispatch`):

```sh
git tag v0.1.0
git push origin v0.1.0
```

On a `macos-14` runner it checks out the repo, imports your Developer ID
cert into a temporary keychain, stores notary credentials, exports
`SIGN_IDENTITY` / `NOTARY_PROFILE`, runs
`./script/build-app.sh --notarize --no-bump` (the tag is the version of
record, so the tracked `BUILD_NUMBER` is left untouched), then uploads
the produced `build/ThreadTidy.zip` to the GitHub Release for the tag as
`ThreadTidy-<tag>.zip`.

### Required repository secrets

Set these under **Settings → Secrets and variables → Actions** in the
GitHub repo:

| Secret | Holds |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of your exported Developer ID Application cert (`.p12`, private key included). |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Any throwaway password CI uses to create/unlock the temporary keychain. |
| `SIGN_IDENTITY` | The full quoted identity, e.g. `Developer ID Application: Your Name (TEAMID)`. |
| `APPLE_ID` | The Apple ID email used for notarization. |
| `APPLE_TEAM_ID` | Your 10-character Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | The app-specific password from <https://appleid.apple.com>. |

### Exporting the cert for `MACOS_CERTIFICATE_P12_BASE64`

In **Keychain Access**, find your **Developer ID Application** identity,
right-click → **Export…**, save as a `.p12` (it will ask for a password —
that becomes `MACOS_CERTIFICATE_PASSWORD`). Then base64-encode it for the
secret value:

```sh
base64 -i cert.p12 | pbcopy
```

Paste the clipboard contents as the `MACOS_CERTIFICATE_P12_BASE64`
secret. Delete the local `.p12` afterward if you don't need it.

---

## Troubleshooting

| Error | Likely cause | Fix |
|---|---|---|
| `error: SIGN_IDENTITY env var is required for --notarize` | `SIGN_IDENTITY` not exported. | `export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"` (or set the CI secret). |
| `0 valid identities found` | Cert not installed in this Mac's login keychain. | Re-install via Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application. |
| `The signature does not include a secure timestamp` | Codesign couldn't reach Apple's timestamp server. | Retry; usually a transient network issue. |
| `The binary is not signed with a valid Developer ID certificate` | Wrong identity name or expired cert. | Run `security find-identity -v -p codesigning` and export the exact name in `SIGN_IDENTITY=`. |
| `The executable does not have the hardened runtime enabled` | An inner binary missed `--options runtime`. | All `codesign` invocations in `build-app.sh` already pass `--options runtime`; if a new bundled binary is added, sign it the same way before the outer .app. |
| `Invalid credentials` from notarytool | Wrong profile name, or the app-specific password was revoked. | Re-run the `xcrun notarytool store-credentials` command with a fresh password. |
| Notarization status `Invalid` | Apple's checks rejected the bundle. | Run `xcrun notarytool log <submission-id> --keychain-profile ThreadTidy-notary` for the JSON report — it lists every issue (e.g. "binary X is not hardened"). |

---

## Distribution checklist

Before sharing `build/ThreadTidy.zip`:

- [ ] `spctl -a -t exec -vv build/ThreadTidy.app` ends with
      `accepted / source=Notarized Developer ID`.
- [ ] `xcrun stapler validate build/ThreadTidy.app` ends with
      `The validate action worked!`.
- [ ] `codesign --verify --strict --deep --verbose=2 build/ThreadTidy.app`
      returns `valid on disk` and `satisfies its Designated Requirement`.

Each of these is run automatically by the script; if any fail, the
script aborts with the error before producing the zip.
