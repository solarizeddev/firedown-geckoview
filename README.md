# firedown-geckoview

Builds a **patched GeckoView** for the [Firedown](https://github.com/solarizeddev/firedown)
Android browser from Firefox source, the way IronFox/Mull do — so changes that
can't be made from the embedding app (they live inside GeckoView's own compiled
code) ship in the engine.

It applies a small, deliberate set of modifications:

| # | Modification | How |
|---|--------------|-----|
| **passkeys** | Route WebAuthn through **Android Credential Manager** instead of Google's allowlist-gated GMS FIDO2 browser API (the `microg-unbreak-fido` change) — so passkey logins prompt in a non-allowlisted fork. | `firedown/patches/0001-*` (Java edit) |
| **DRM off** | Disable EME/Widevine at build (`--disable-eme`) **and** as a default pref (`media.eme.enabled=false`). | mozconfig + `0002` prefs |
| **telemetry off** | Strip crash reporter + reporting code at build, neutralize telemetry/Normandy/health-report via default prefs. | mozconfig + `0002` prefs |
| **Pocket/sponsored off** | Engine-level Pocket + activity-stream sponsored prefs off (most of this is Fenix-UI, absent from Firedown — included defensively). | `0002` prefs |
| **hardened privacy** | IronFox-style defaults: query stripping, GPC/DNT, network-state partitioning, referrer trimming, no beacons/prefetch/predictor. | `0002` prefs |

Why these are *defaults* (prefs): Firedown's `GeckoPreferenceController` can still
override any of them at runtime, so the build stays flexible. Why the FIDO one is
a code patch: it's a guarded branch inside `WebAuthnTokenManager`, not a pref.

---

## Requirements (Arch Linux)

- ~**40–60 GB** free disk, a fast SSD, and **16 GB+ RAM** (more is better).
- Hours for the first `mach build` (subsequent incremental builds are fast).
- Outbound network to GitHub/Mozilla (source + `mach bootstrap` toolchain).

`mach bootstrap` fetches the Android SDK/NDK, Rust toolchain and a vendored JDK
into `~/.mozbuild`; you only need host basics (step `prereqs` installs them).

## Quickstart

```bash
git clone <this repo> firedown-gecko
cd firedown-gecko

# edit config/build.env if you want a different version/ABI/source method
$EDITOR config/build.env

./build.sh prereqs     # 00  pacman host packages (uses sudo)
./build.sh all         # 01-05: fetch → bootstrap → patch → build → sync
```

Or run the stages individually:

```bash
./build.sh fetch       # 01  download Firefox source per SOURCE_METHOD
./build.sh bootstrap   # 02  mach bootstrap (Android toolchain)
./build.sh patch       # 03  apply Firedown patches (idempotent)
./build.sh build       # 04  mach build + publish AAR to ~/.m2 (mavenLocal)
./build.sh sync        # 05  print the firedown app/build.gradle wiring
./build.sh sync --apply  #   …and patch the firedown checkout in place
```

## Wiring the result into the app

`build` publishes `org.mozilla.geckoview:geckoview-…:<version>` to `~/.m2`
(mavenLocal) **with its POM**, so transitive deps resolve. `sync` detects the
exact artifactId/version (it varies by flavor) and prints the two edits:

1. add `mavenLocal()` first in `settings.gradle` repositories;
2. point `app/build.gradle`'s geckoview line at the local artifact.

It also reminds you to **revert the experimental microG `play-services-fido`
swap** on the `claude/jolly-dirac-mSEby` branch — the source build bakes the FIDO
fix in, so that throwaway exclude is no longer needed.

## Configuration (`config/build.env`)

- `FIREFOX_VERSION` / `FIREFOX_TAG` — what to build. Keep the **major** in step
  with the app's `geckoviewVersion`.
- `SOURCE_METHOD` — `git` (default, shallow clone), `tarball`, or `hg`.
- `ANDROID_TARGETS` — space-separated ABI triples. Defaults to
  `aarch64-linux-android x86_64-linux-android` (arm64-v8a + x86_64).
- `FIREDOWN_APP` — path to your firedown checkout for `sync --apply`.

## ABIs / multi-arch

We ship **arm64-v8a** (phones/tablets) and **x86_64** (emulators/Chromebooks).
`04-build.sh` runs two phases: build each ABI separately (real native compile,
one objdir each) producing a per-ABI AAR, then a **fat-AAR** repackage pass
(`--disable-compile-environment`, so it's fast) combines them into one multi-ABI
artifact and publishes it. Change the set via `ANDROID_TARGETS` in
`config/build.env`; a single ABI just makes the fat pass a one-input combine.

## Updating to a new Firefox version

1. Bump `FIREFOX_VERSION`/`FIREFOX_TAG` in `config/build.env`.
2. `rm -rf gecko/` and re-`fetch`.
3. Re-`patch` — the appliers are marker-gated and **fail loudly** if an anchor
   moved (e.g. the `WebAuthnTokenManager` decision site), so you'll know exactly
   what to re-verify instead of silently shipping an unpatched engine.

## Honesty / caveats

- `--disable-eme` and the `MOZ_*` telemetry switches in the mozconfig are
  best-effort across versions; if configure rejects one it **warns** (we keep
  them on separate lines) and the default prefs still disable the same thing at
  runtime. Comment any offender.
- The Pocket/sponsored prefs are mostly Fenix-layer and largely inert in a bare
  GeckoView — kept for completeness, not because Firedown shows that UI.
- This tree never commits the Gecko source or build outputs (see `.gitignore`).
