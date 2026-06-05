# CLAUDE.md — firedown-geckoview

Guidance for Claude (and other agents) working in this repo. It builds a
**patched GeckoView** for the Firedown Android app from Firefox source (the
IronFox/Mull approach). The app repo (`firedown`) consumes the resulting AAR;
its `CLAUDE.md` has the media-capture/download context. The native ffmpeg fork
lives in `firedown-ffmpeg`.

## Session handoff — READ FIRST

This repo lives at **`solarizeddev/firedown-geckoview`**. It was bootstrapped in a
prior session.

- **Canonical branch: `main`.** Continue work there (one working branch — don't
  cut a new one per task, same rule as the other Firedown repos). The
  `claude/jolly-dirac-mSEby` branch also exists and holds the same tree; keep the
  two in lockstep if you touch both, but `main` is the source of truth.
- Push with `git push -u origin main` (retry with exponential backoff on network
  errors). Don't open a PR unless asked.
- The build/patch design is below. Nothing here has been compiled yet — the next
  build runs on the user's Arch machine. **Do not run a full `mach build`
  in-session.** If asked to verify, the cheap gate is
  `./build.sh fetch && ./build.sh patch` (confirms the WebAuthn anchor still
  matches the target Firefox version before any multi-hour compile).

## What this repo does

`build.sh` drives five stages (`scripts/0X-*.sh`): fetch Firefox source →
`mach bootstrap` the Android toolchain → apply Firedown's modifications →
build each ABI + fat-AAR them and publish to `~/.m2` (mavenLocal) → print/apply
the app's gradle wiring. Settings live in `config/build.env` (version,
`ANDROID_TARGETS`, source method, app path). We ship **arm64-v8a + x86_64**.

We build from source **because these changes can't be made from the embedding
app** — they're inside GeckoView's own compiled code or default prefs. The
flagship one is routing WebAuthn through Android Credential Manager instead of
the cert-allowlist-gated GMS FIDO2 path (see the app repo's WebAuthn notes).

## The Firedown modifications (`firedown/`)

Two delivery mechanisms, mirroring `firedown-ffmpeg`'s **idempotent,
marker-gated** convention (`apply-firedown-patches.sh` is safe to re-run; each
patch is gated on a marker or canonical content):

| kind | file | purpose |
|------|------|---------|
| Java edit | `firedown/patches/0001-webauthn-credential-manager.sh` | Force `WebAuthnTokenManager` to use Android Credential Manager — rewrites the `if (!BuildConfig.MOZILLA_OFFICIAL)` gate(s) to `if (true)`. Marker `FIREDOWN-WEBAUTHN-CREDMAN`. **Fails loudly** if the anchor moved. |
| pref append | `firedown/patches/0002-default-prefs.sh` + `firedown/prefs/firedown-geckoview.js` | Append default prefs (DRM-off, telemetry-off, Pocket/sponsored-off, hardened privacy) to `mobile/android/app/geckoview-prefs.js`. Marker `FIREDOWN-GECKO-PREFS`. |
| build flags | `mozconfig/geckoview-release.mozconfig` | Build-level switches: `--disable-eme` (DRM), `--disable-crashreporter`, `MOZ_TELEMETRY_REPORTING=`/`MOZ_DATA_REPORTING=`/`MOZ_NORMANDY=`, release/Android target. |

Division of labor: **prefs are defaults** (Firedown's `GeckoPreferenceController`
can still override at runtime, so nothing hard-conflicts); **build flags** remove
code/endpoints at compile time (belt-and-suspenders with the prefs); the **Java
edit** is the one thing that must be a code patch (it's a guarded branch, not a
pref).

### Why the appliers fail loudly, not silently

A silent no-op here ships an **unpatched engine** — e.g. passkeys quietly back to
the GMS allowlist. So `0001` errors if `if (!BuildConfig.MOZILLA_OFFICIAL)` isn't
found and `0002` errors if `geckoview-prefs.js` moved. On a version bump that's
the signal to re-verify the anchor, not to relax the check.

## DRM / EME — two layers

`--disable-eme` (mozconfig) removes the EME plumbing at build; `media.eme.enabled
= false` (prefs) disables it at runtime. If a Firefox version's configure rejects
`--disable-eme`, drop that one line — the pref still disables DRM, so nothing
functional is lost. Don't make DRM-off depend on the build flag alone.

## WebAuthn → Credential Manager (the important patch)

GeckoView delegates WebAuthn to Google Play Services' FIDO2 **browser** API,
gated by a package+signing-cert allowlist Google doesn't grant indie forks
(Firedown's cert is rejected by `FidoBrowserApiChimeraService`). GeckoView also
has an **Android Credential Manager** path (`androidx.credentials`, **not**
allowlist-gated), guarded by `if (!BuildConfig.MOZILLA_OFFICIAL)` — false in an
official prebuilt AAR. `0001` forces that gate true so every WebAuthn op uses
Credential Manager and the user's passkey provider prompts. This is exactly why
the prebuilt-AAR route can't fix it (the constant is compiled in) and a source
build can. See the app repo's CLAUDE.md "passkey/WebAuthn" notes for the full
investigation (the GMS allowlist rejection, why reflection/prefs can't bypass it).

## Build / publish mechanics

- **Phase 1 (per ABI):** `mach build` cross-compiles Gecko (C++/Rust) for each
  triple in `ANDROID_TARGETS` into its own objdir; the heavy first-time step.
  Each yields a per-ABI `geckoview-…-withGeckoBinaries-release.aar`.
- **Phase 2 (fat-AAR):** a `--disable-compile-environment` pass (repackage only,
  fast) with `MOZ_ANDROID_FAT_AAR_ARCHITECTURES` + `MOZ_ANDROID_FAT_AAR_<ABI>`
  combines the per-ABI AARs and publishes via `./mach gradle
  geckoview:publishWithGeckoBinariesReleasePublicationToMavenLocal` —
  `withGeckoBinaries` = the real libs (not the stub), and a mavenLocal publish
  carries the **POM with transitive deps** (a bare `.aar` in `app/libs` would
  miss them).
- The published **artifactId varies by flavor**, so `05-sync-to-app.sh` detects
  it from `~/.m2` rather than hardcoding, and prints/edits the app's
  `settings.gradle` (`mavenLocal()`) + `app/build.gradle` (the geckoview line).

## After changing a patch / bumping the version

- Bump `FIREFOX_VERSION`/`FIREFOX_TAG` in `config/build.env`; `rm -rf gecko/`;
  re-`fetch`.
- Re-run `./build.sh patch` and confirm each applier reports `[ok]` (not an
  anchor error). Re-running is idempotent (`[skip]` once markers are present).
- Rebuild and re-`sync`. Revert the app's experimental microG
  `play-services-fido` swap (the source build supersedes it).

## Conventions

- Don't commit the Gecko source tree or build outputs (`.gitignore`).
- Keep appliers idempotent and marker-gated; prefer appending prefs or a precise
  anchored edit over fragile context-diff `.patch` files.
- Develop on `main` (the canonical branch); open a PR only when asked.
- Match the surrounding comment density — explain *why* (including dead-ends),
  same as the other two repos.
