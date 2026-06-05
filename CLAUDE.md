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
- The build/patch design is below. **Do not run a full `mach build` in-session.**
  If asked to verify, the cheap gate is `./build.sh fetch && ./build.sh patch`
  (confirms the patch anchors still match the target Firefox version before any
  multi-hour compile).
- **Build status:** driven on the user's Arch box. The reuse-existing-SDK/NDK
  path (FF 151, NDK r29) cleared configure and compiled ~4 min of Gecko, then hit
  a **hard wall**: the host's bleeding-edge **glibc** breaks Firefox's vendored
  `glsl-optimizer` (`once_flag`/`call_once` redefinition) — *not* a toolchain
  problem, and unfixable from the mozconfig (see the glibc lesson below). **The
  resolution is `./build.sh docker`** — build in a stable-glibc container. Prefer
  that on Arch / any too-new-glibc host. The elaborate skip-bootstrap
  compensations below still apply on a host whose glibc isn't too new.

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
| Rust edit | `firedown/patches/0004-noop-glean-endpoints.sh` | Blank the Glean/FOG telemetry + OHTTP **upload endpoints** in `toolkit/components/glean/src/init/{mod.rs,viaduct_uploader.rs}` (→ `""`), so the compiled-in telemetry SDK has nowhere to POST. Defense-in-depth atop the runtime `uploadEnabled=false` pref; mirrors IronFox's `noop_mozilla_endpoints.sh` for the FOG layer. Marker `FIREDOWN-GLEAN-NOOP`. **Fails loudly** if an endpoint string moved. |
| build flags | `mozconfig/geckoview-release.mozconfig` | Build-level switches: `--disable-crashreporter`, `--disable-parental-controls`, `--enable-strip`/`--enable-install-strip` (shrink libxul), release/Android target. (`--disable-eme` and the telemetry/healthreport/normandy `MOZ_*` vars were removed — FF 151 configure rejects them, "can not be set by mozconfig … accepted from: implied"; those layers are covered by runtime prefs + the non-official build.) |

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

## Telemetry / Glean — compiled in, neutered two ways

Glean (the Rust `glean-core` + `firefox-on-glean`/FOG) **compiles into GeckoView**
— it's wired through thousands of instrumentation call sites, so there's no build
flag to remove it (you'll see `glean-core` / `firefox-on-glean` compile, that's
expected). It's neutered on two layers:
1. **Runtime pref** — `datareporting.healthreport.uploadEnabled=false` (Glean's
   master upload switch) + `toolkit.telemetry.*` off, in `firedown-geckoview.js`.
   From a fresh profile that's never enabled, Glean collects/sends nothing (not
   even the one-time deletion-request ping).
2. **Source neuter (`0004`)** — blanks the FOG upload + OHTTP endpoint URLs to
   `""`, so even if upload were somehow enabled there is **no server to POST to**.

Scope note (don't "rediscover" this): IronFox disables Glean far more
aggressively, but most of it is **app-layer** — Kotlin `glean-core` overlay stubs
(`upload()→Incapable`, `Glean.initialize(){return}`) and Fenix/android-components/
app-services "liberate" patches that remove the *callers*. **None of that is in a
bare GeckoView AAR** (Firedown supplies its own app shell). The only IronFox Glean
technique that maps onto our build is the FOG endpoint neuter, which is exactly
what `0004` does. IronFox sets **no** `datareporting.*`/`toolkit.telemetry.*` prefs
(it relies on the structural removal); we keep the prefs **and** add the source
neuter, so our build is strictly at-or-beyond IronFox on actual Glean behavior.

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

## Skip-bootstrap toolchain compensations (reuse-existing-SDK/NDK path)

Setting `ANDROID_SDK_ROOT`/`ANDROID_NDK_ROOT` in `config/build.env` (they also
honour exported `ANDROID_HOME`/`ANDROID_NDK_HOME`) makes `02-bootstrap.sh` **skip
`mach bootstrap`** and its multi-GB download. But bootstrap provisions the *whole*
toolchain, so reusing your own SDK/NDK means you must supply everything else.
`04-build.sh` injects the rest into each per-ABI mozconfig (all **gated on the
reuse path** — a normal `mach bootstrap` build is untouched: Mozilla clang+sysroot,
fetched wasi-sysroot, RLBox on). The full list, learned the hard way (each one was
a distinct configure/compile failure):

| bootstrap provides | reuse-path replacement (in `04-build.sh` unless noted) | symptom if missing |
|---|---|---|
| Android SDK/NDK | `--with-android-sdk` / `--with-android-ndk` | "You must install the Android platforms…" |
| target compiler | `CC`/`CXX` = the **NDK's** clang | system clang lacks Android `compiler-rt`/`libunwind` → link conftest fails |
| host compiler | `HOST_CC`/`HOST_CXX` = **system** clang | setting only `CC` makes host build tools (glslopt) use the NDK clang too |
| host sysroot | `--enable-bootstrap=+sysroot-x86_64-linux-gnu` (small fetch) | **glslopt vs new glibc** — see below |
| wasi-sysroot (RLBox) | `WASI_SYSROOT` → `--with-wasi-sysroot` + `WASM_CC`/`WASM_CXX`=system clang | "Cannot find wasi headers"; then wasm-ld can't find `libclang_rt.builtins-wasm32.a` (NDK clang has no wasm builtins; system clang + Arch `wasi-compiler-rt` does) |
| vendored JDK | `--with-java-bin-path` = `$JAVA_HOME`/Arch openjdk-17 | "Could not locate Java at ~/.mozbuild/jdk/…" |
| bundletool.jar | `02-bootstrap.sh` fetches it to `~/.mozbuild` (`BUNDLETOOL_VERSION`) | "You must install Bundletool" |
| Rust std targets | `04-build.sh` + `00-prereqs` `rustup target add` per ABI | "can't find crate for std" |
| host tools (llvm-objdump, cbindgen) | `00-prereqs-arch.sh` packages (`llvm`, `rust-cbindgen`) | "Cannot find llvm-objdump", missing cbindgen |

Still **manual** (version-pinned by Firefox, so we don't fetch blindly): the SDK
**platform** — `sdkmanager "platforms;android-36.1"` — and the **NDK must be the
exact version FF pins (r29 for 151)**; configure validates it.

### The big lesson: bleeding-edge distro glibc vs vendored C

The one issue that *isn't* about tool location: the vendored **`glsl-optimizer`**
(behind the `glslopt` host build crate) won't compile against a very new glibc —
glibc now declares C11/C23 `once_flag`/`call_once` (in `stdlib.h` /
`bits/types/once_flag.h`) that collide with glsl-optimizer's bundled `c11/threads`
shim (`typedef redefinition`, `static declaration of call_once follows
non-static`). It is **compiler-independent** (system clang hits it too), so
`HOST_CC` doesn't fix it. Mozilla's CI never sees it because it compiles host code
against a **pinned older-glibc sysroot**.

Things that were tried on the host and **did NOT work** (don't repeat them):
`HOST_CC`=system clang (host now used system clang — same error); and
`--enable-bootstrap[=+sysroot-x86_64-linux-gnu]` — configure accepts it, but the
host sysroot is **not propagated to cargo build-scripts** (cc-rs invokes
`/usr/bin/clang … -I…/dist/include` with `CFLAGS_<host>` that carries **no
`--sysroot`**), so glslopt still compiles against the system glibc. The reliable
fix is **`./build.sh docker`** — a stable-glibc container running the normal
bootstrap (see the Docker section). Patching the vendored glsl-optimizer was the
only no-container alternative and is fragile (more glibc conflicts downstream).

RLBox note: `WASI_SYSROOT` empty → `--without-wasm-sandboxed-libraries` (libs run
native, *faster* but un-sandboxed — sandboxing is a security feature, not a perf
one). Set it (Arch `wasi-libc` at `/usr/share/wasi-sysroot`, plus
`wasi-compiler-rt`) to keep RLBox.

## Building in Docker (the glibc fix — RECOMMENDED on Arch)

`./build.sh docker` (→ `docker/build-in-docker.sh`, image from `docker/Dockerfile`)
builds inside **Ubuntu 22.04** (stable, older glibc). This is the clean fix for the
glibc-vs-`glsl-optimizer` wall the host build hits, and it's reproducible. Key
design choices:

- **It runs the FULL `mach bootstrap` path, not the reuse path.** The container
  deliberately does *not* set `ANDROID_SDK_ROOT`/`ANDROID_NDK_ROOT`/`WASI_SYSROOT`,
  so bootstrap provisions **Mozilla's tested clang + host sysroot + wasi-sysroot +
  SDK + NDK + JDK**. glslopt compiles (Mozilla's older-glibc host sysroot), RLBox
  works (Mozilla's wasi), and none of the skip-bootstrap compensations are needed.
  So inside Docker the whole "supply your own toolchain" saga simply doesn't apply.
- **Caches are host-owned bind mounts under `.docker-build/`** (gitignored):
  `gecko/` (the checkout), `mozbuild/` (toolchain + SDK/NDK), `cargo/`. Re-runs are
  incremental; nothing huge re-downloads. The image's `builder` user is created with
  the host UID/GID (`--build-arg`) so those mounts stay writable both sides.
- **The AAR publishes to the host's `~/.m2`** (mounted in), so the firedown **app**
  build still runs on the host (gradle/Java don't care about glibc) and resolves it
  via `mavenLocal()` — `./build.sh sync` as usual.
- Pass stages through: `./build.sh docker` = `all`; `./build.sh docker build` runs a
  single stage in the container.

Our app-facing mozconfig choices (version pin, `--enable-strip`, telemetry/DRM
prefs, patches `0001`–`0003`, `BUILD_JOBS`) all still apply inside the container —
only the *toolchain-acquisition* differs (bootstrap vs reuse).

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
