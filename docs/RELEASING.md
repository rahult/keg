# Releasing Keg

Keg ships as a notarized DMG on GitHub Releases, and updates itself through
Sparkle from a feed served at `https://keg.rahultrikha.com/appcast.xml`.

## One-time setup

Run the wizard. It generates the Sparkle signing key, walks through exporting
your Developer ID certificate and creating an app-specific password, and sets
all seven repository secrets:

```sh
./Scripts/setup-release.sh
```

It writes `Resources/sparkle-public-key.txt`. **Commit that file** — the public
key ships inside the app so Keg can verify an update really came from you, and
`make release-app` refuses to build without it.

The seven secrets it sets:

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE` | Developer ID Application .p12, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | The password you set when exporting it |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: Rahul Trikha (7MLJLH4J76)` |
| `APPLE_ID` | Apple ID email, for notarization |
| `APPLE_PASSWORD` | App-specific password — never the account password |
| `APPLE_TEAM_ID` | `7MLJLH4J76` |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key that signs each update |

DNS is already in place: `keg.rahultrikha.com` is a CNAME to `rahult.github.io`,
and `site/CNAME` is what tells GitHub Pages to answer for it.

## Cutting a release

```sh
gh workflow run release.yml -f version=0.2.0
gh run watch
```

That tags `v0.2.0` and, in the same run, builds it. Pushing a `v*` tag by hand
does the same thing minus the tagging step, which is the way to retry a release
whose build failed after the tag already existed.

What the run does, in order:

1. **tag** — validates the version is semver, creates and pushes `v0.2.0`.
2. **release** — on a `macos-26` arm64 runner: tests, imports the certificate,
   then `make release` builds the app, embeds and signs Sparkle inside-out,
   notarizes and staples the bundle, and produces the DMG and the ZIP.
   It checks Gatekeeper actually accepts the result before publishing, then
   generates the EdDSA-signed appcast.
3. **publish-feed** — commits `site/appcast.xml` and `site/version.json` to
   main and dispatches the site deploy.

Three assets end up on the release:

- `Keg.dmg` — un-versioned on purpose, so
  `https://github.com/rahult/keg/releases/latest/download/Keg.dmg` is a
  permanent link the site never has to regenerate.
- `Keg-0.2.0.dmg` — the same image under a versioned name.
- `Keg-0.2.0.zip` — what Sparkle downloads.

## Versioning

The git tag is the only source of truth. `make version` derives
`CFBundleShortVersionString` from `git describe --tags`; CI passes it
explicitly from the tag being built.

`CFBundleVersion` is the GitHub Actions run number, because Sparkle compares
*that*, not the marketing version, and it has to increase with every published
build. A local `make app` stamps build `1`, which the About panel deliberately
hides so it is never mistaken for a real build number.

## Building locally

```sh
make app       # signs with any identity — for running it yourself
make dmg       # a disk image, unnotarized
make release   # the full distribution path; needs Developer ID + APPLE_* env
```

`make release` reads `APPLE_ID`, `APPLE_PASSWORD` and `APPLE_TEAM_ID` from the
environment. The wizard offers to store them in your keychain as the
`keg-notarization` profile, and writes the non-secret ones to `.env.release`
(gitignored).

## How auto-update behaves

Sparkle asks permission to check for updates on second launch — that prompt is
deliberately left to Sparkle rather than switched on in `Info.plist`, because
turning on something that talks to the network on someone's behalf should be
their call.

Defaults, all changeable in **Settings → Software Update**:

- **Check automatically** — whatever the user answered to Sparkle's prompt.
- **Frequency** — daily.
- **Download and install automatically** — off. Sparkle installs a background
  download when the app quits, which is safe in itself, but Keg usually sits in
  the menu bar beside running containers, and spending someone's bandwidth and
  swapping the binary underneath that is not a default worth having.

"Check for Updates…" sits in the Keg menu directly under "About Keg", where
every Mac app puts it.

## If a release fails

The tag survives a failed build, so fix the problem and re-push the tag
(`git tag -f v0.2.0 && git push -f origin v0.2.0`) or re-run the failed job.
Notarization is the step most likely to stall — Apple's queue is occasionally
slow, and the job has a 60-minute cap so it fails rather than burning the
six-hour default.

If the appcast is wrong, the fix is a new release rather than an edit: the
signature covers the archive, so a hand-edited feed will simply be rejected by
every installed copy of Keg.
