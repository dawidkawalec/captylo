# Releasing Captylo

How a public version gets from this repository to `captylo.com/download/Captylo.dmg` and to the copies people already have (Sparkle updates). Short on purpose; the scripts print every step and stop with a clear message when something is missing.

Pieces: `scripts/release.sh` (`make dist`, `make dist-dry`), `scripts/sign-app.sh`, `scripts/make-dmg.sh`, `scripts/appcast.py` (appcast item, release notes page, the version on the site, the pre-publish check; tests: `python3 -m unittest scripts/test_appcast.py`), `scripts/publish-release.sh` (`make publish`, `make publish-check`), `deploy/Caddyfile.captylo.snippet`. Background: "Signing" and "Updates" in [architecture.md](architecture.md).

## Once

1. **Developer ID certificate.** Xcode > Settings > Accounts > the team > Manage Certificates > "+" > Developer ID Application. It lands in the login Keychain. Check: `security find-identity -v -p codesigning | grep "Developer ID Application"` prints exactly one line (with more than one, run `make dist DIST_IDENTITY="<full certificate name>"`). Keep a `.p12` export with its password outside the repo. The first real signature makes macOS ask whether codesign may use the key: type the login password and choose "Always Allow", or every later signature waits for that prompt.
2. **Notarization profile.** Create an App Store Connect API key (Users and Access > Integrations > App Store Connect API, role Developer), download `AuthKey_<KEYID>.p8` into a private folder outside the repo (chmod 600), then:
   `xcrun notarytool store-credentials captylo-notary --key <folder>/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER>`.
   The profile lives in the login Keychain. An app-specific password works too (`--apple-id`, `--team-id`, `--password`).
3. **Sparkle EdDSA key.** After any `make build` (SwiftPM fetches Sparkle and its tools):
   `.local-build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
   It keeps the private key in the login Keychain and prints the public key. Put the public key into `SPARKLE_PUBLIC_ED_KEY` in `project.yml` (it is public, it belongs in the repo) and commit. Back up the private key at once: `generate_keys -x <private folder>/sparkle-ed25519.key` (chmod 600) and keep a copy off this Mac. While the key is still `REPLACE_ME`, the app never checks for updates and a real `make dist` refuses to run.
4. **The server.** Copy `deploy/local.env.example` to `deploy/local.env` (git-ignored) and fill in the host and folders. On the server: create the `PUBLISH_DOWNLOADS` folder, make it visible inside the Caddy container, add `deploy/Caddyfile.captylo.snippet` (with `DOWNLOADS_DIR` replaced by that folder as the container sees it) inside the `captylo.com` block before `file_server` (backup, edit in place, `caddy validate`, reload), and a HEAD monitor for `https://captylo.com/download/Captylo.dmg`. The downloads folder sits outside the site's web root because the site sync deletes everything that is not in `site/`.

## Every release

1. **Version.** Bump `MARKETING_VERSION` in `project.yml` by hand (`1.0.1`), commit. The build number is not edited anywhere: `CFBundleVersion` = `git rev-list --count HEAD` when the release is built, so it only grows on `main`, which is what Sparkle compares.
2. **Notes.** Write `dist/<version>/notes.md` in Polish (headings, paragraphs, `- ` lists, `**bold**`, `` `code` ``, links). `dist/` is never committed; the rendered page `site/updates/notes/<version>.html` is. No cloud vendor names in the notes.
3. **Optional rehearsal.** `make dist-dry VERSION=<version>`: same build, signed with "Captylo Dev", no notarization, appcast and notes only in `dist/<version>/`. It lists what a real run would refuse.
4. **Build.** On `main` with a clean tree: `make dist VERSION=<version>`. It checks the prerequisites above, builds, signs inside-out, notarizes the app (as a zip) and staples it, packages and signs the DMG, notarizes and staples the DMG, mounts it and launches the app from it, asks Gatekeeper (`spctl`), signs the update with `sign_update` and writes `site/updates/appcast.xml`, `site/updates/notes/<version>.html` and the version in the download block of `site/index.html`. Notarization usually takes a few minutes; the script waits up to 30.
5. **Commit and push** `site/updates/` and `site/index.html` ("Release Captylo <version>"), push `main`.
6. **Publish.** `make publish-check VERSION=<version>` (local only: Developer ID DMG, stapled ticket, appcast item newest and signed with the right size, notes page, version on the site, `site/` committed, commit on `origin/main`). Then `make publish VERSION=<version>`: it asks once ("publish"), uploads the DMG, points `Captylo.dmg` at it, checks both download URLs, syncs `site/` (with the appcast), checks the live appcast and creates the GitHub release `v<version>` with the DMG and `notes.md`. Safe to run again.
7. **Check.** `curl -sI https://captylo.com/download/Captylo.dmg` (200, the DMG's size), and on an installed older copy "Sprawdź aktualizacje…" offers the new version.

## When notarization is rejected

`release.sh` prints Apple's log (`xcrun notarytool log <id> --keychain-profile captylo-notary`). Almost always a nested binary without the hardened runtime, without a secure timestamp or not signed by Developer ID: look for the path in the log, check `codesign -dvvv <path>` on `dist/<version>/Captylo.app`, fix `scripts/sign-app.sh` if a new nested item appeared (a new framework, XPC service or helper), and run `make dist` again. Nothing was published, so a rerun is harmless. `spctl -a -vv dist/<version>/Captylo.app` should end with "source=Notarized Developer ID".

## Keys and what losing them means

- **Sparkle private key** (login Keychain, backup `sparkle-ed25519.key` in the private folder): signs every update. Without it no installed copy accepts a new version, and the only way out is a new key in a manually downloaded build. Restore with `generate_keys -f <backup file>`.
- **Developer ID certificate** (login Keychain, `.p12` backup): a renewed or replacement certificate from the same team keeps both updates and people's permissions working, because the app's designated requirement names the team, not one certificate.
- **Notary API key** (`AuthKey_<KEYID>.p8`): can be revoked and created again at any time; rerun `store-credentials`.

Never commit a `.p12`, a `.p8`, a key file or a password; `.gitignore` covers them and `dist/`.

## Permissions after the switch to Developer ID

The released app has a different signature from development builds ("Captylo Dev" or ad-hoc), so on a Mac that ran a development build macOS asks for Microphone, Accessibility, Calendar and System Audio once more. That is expected; there is no migration. Development builds keep their own grants (`make reset-tcc` resets them).
