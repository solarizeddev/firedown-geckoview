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
| pref append | `firedown/patches/0002-default-prefs.sh` + `firedown/prefs/firedown-geckoview.js` | Append default prefs (DRM-off, telemetry-off, Pocket/sponsored-off, hardened privacy, plus IronFox-derived connection/add-on-probe + phone-home-endpoint prefs) to `mobile/android/app/geckoview-prefs.js`. Marker `FIREDOWN-GECKO-PREFS`. |
| Java/C++ edit | `firedown/patches/0003-disable-network-id.sh` | Make `nsAndroidNetworkLinkService::GetNetworkID` return an empty network ID (drops the network-change fingerprint/correlation signal). IronFox-derived (`gecko-disable-network-id`), Android-only. Marker `FIREDOWN-NETWORK-ID`. **Fails loudly** if the method body anchor moved. |
| build flags | `mozconfig/geckoview-release.mozconfig` | Build-level switches: `--disable-crashreporter`, `MOZ_TELEMETRY_REPORTING=`/`MOZ_DATA_REPORTING=`/`MOZ_NORMANDY=`, release/Android target. (`--disable-eme` was removed — FF 151 configure rejects it; DRM-off is the runtime pref.) |

Division of labor: **prefs are defaults** (Firedown's `GeckoPreferenceController`
can still override at runtime, so nothing hard-conflicts); **build flags** remove
code/endpoints at compile time (belt-and-suspenders with the prefs); the **Java
edit** is the one thing that must be a code patch (it's a guarded branch, not a
pref).

### IronFox patch triage — what we deliberately did NOT take

Firedown is a **downloader first**; the cardinal constraint is that media capture
keeps working (see the app repo's CLAUDE.md on the scoped-not-global
fingerprinting story). IronFox (gitlab.com/ironfox-oss/IronFox) is a hardened
*general-purpose* browser, so a lot of its engine patches are neutral-to-harmful
here. When pulling more from IronFox, keep these **deliberate skips** in mind —
each one would break capture or the app, so don't "rediscover" them:

- **`gecko-fix-canvas-randomization`** — makes canvas noise more aggressive
  (applies under `EfficientRandomize`, stops skipping uniform pixel groups). This
  collides head-on with the app's *scoped* TikTok canvas-randomization override;
  taking it globally risks the very "Something went wrong" throttle the app works
  to dodge. **Never.**
- **`geckoview-disable-network-connectivity-monitoring`** — strips
  `ACCESS_NETWORK_STATE` + `GeckoNetworkManager`. A downloader wants network-state
  awareness. **No.**
- **`gecko-remove-privileged-addon-signing-status`** — could de-privilege the
  bundled built-in WebExtensions (parser/uBO). **No.**
- **`gecko-support-safe-browsing-download-protection`** — sends download URLs to
  Google's reputation service. Anti-privacy for a no-telemetry build. **No.**
- **`gecko-rs-blocker` / `gecko-certificate-pinning`** — the RS allowlist can
  break cert-revocation/CRLite; the pins are IronFox's own domains. **No.**
- **`geckoview-liberate`** (microG `play-services-fido` swap) — superseded by
  `0001` (Credential Manager doesn't use FIDO2/GMS at all). The app's notes even
  say to *revert* the experimental microG FIDO swap once the source build lands.
- Already covered by our prefs / mozconfig and skipped as redundant:
  `gecko-stub-beacon` (`beacon.enabled=false`), the Nimbus/Normandy patches
  (`app.normandy.*`, `messaging-system.rsexperimentloader.enabled`),
  `geckoview-disable-crash-reporting` (`--disable-crashreporter`).

What we **did** take from IronFox: `0003` (network-id), the speculative-connection
/ mozAddonManager / phone-home-endpoint prefs in `firedown-geckoview.js`, and (as
ever) the WebAuthn→CredManager change that `0001` already implemented
independently.

### Why the appliers fail loudly, not silently

A silent no-op here ships an **unpatched engine** — e.g. passkeys quietly back to
the GMS allowlist. So `0001` errors if `if (!BuildConfig.MOZILLA_OFFICIAL)` isn't
found and `0002` errors if `geckoview-prefs.js` moved. On a version bump that's
the signal to re-verify the anchor, not to relax the check.

## DRM / EME — runtime pref (the build flag is gone)

DRM-off is a two-layer design — `--disable-eme` (mozconfig, build) + `media.eme.enabled
= false` (prefs, runtime) — but **FF 151's mobile/android configure REJECTS
`--disable-eme`** (`InvalidOptionError: --disable-eme is not available in this
configuration`), so the build flag is **removed** from the mozconfig. DRM/EME is
still fully off via the runtime pref (plus the app's `setDRM`), which is why
DRM-off was never allowed to depend on the build flag alone. If a future Firefox
version accepts the flag again, re-add it for belt-and-suspenders compile-time
removal; until then the pref is load-bearing. (Update the modifications table's
"build flags" row too if you change this.)

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

### Pinning the GeckoView version (`MOZ_BUILD_DATE`)

The published Maven coordinate is `<milestone>.<buildid>`, e.g.
`151.0.20260601110758`. The milestone comes from the source; the buildid is
normally the build's wall clock (non-reproducible). `config/build.env`'s
`GECKOVIEW_BUILD_DATE` (14-digit `YYYYMMDDHHMMSS`) pins it — `04-build.sh`
exports it as `MOZ_BUILD_DATE` for **every** mach build (each per-ABI pass *and*
the fat-AAR repackage) so all artifacts agree on the version, and `05-sync`
warns if the published version doesn't match `GECKOVIEW_VERSION`. This is the
coordinate the app's `app/build.gradle` `geckoviewVersion` must reference.
Pinning only changes the version **label** — to ship newer engine code you must
also bump `FIREFOX_VERSION`/`FIREFOX_TAG`. ABIs (`ANDROID_TARGETS`) are
arm64-v8a + x86_64 (`aarch64-linux-android x86_64-linux-android`).

### UTC timezone spoofing is an app toggle, not a build patch

IronFox spoofs the timezone to UTC with a code patch (a custom bool pref read in
`nsRFPService.cpp` that forces `RFPTarget::JSDateTimeUTC`). Firedown needs none
of that: FPP is already on, so `JSDateTimeUTC` is a stock target the app flips at
runtime via `privacy.fingerprintingProtection.overrides` (`+JSDateTimeUTC` on,
clear/`-JSDateTimeUTC` off). It's additive to and independent of the per-site
`granularOverrides` used to scope CanvasRandomization to tiktok.com. Default OFF
(UTC clocks confuse calendar sites; it's a user choice). See the comment block in
`firedown/prefs/firedown-geckoview.js`. Don't add a code patch for this.

## Conventions

- Don't commit the Gecko source tree or build outputs (`.gitignore`).
- Keep appliers idempotent and marker-gated; prefer appending prefs or a precise
  anchored edit over fragile context-diff `.patch` files.
- Develop on `main` (the canonical branch); open a PR only when asked.
- Match the surrounding comment density — explain *why* (including dead-ends),
  same as the other two repos.
