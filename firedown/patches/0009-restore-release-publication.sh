#!/usr/bin/env bash
# 0009 — Restore the geckoview `release` Maven publication (FF153 regression).
#
# WHY: FF153 rewrote mobile/android/geckoview/build.gradle to publish ONLY the
# `debug` variant — `android { publishing { singleVariant('debug') } }` plus a
# single `publishing.publications.create('debug', MavenPublication)`. The
# `release` MavenPublication that 151/152 shipped is gone, so the `release`
# publish task no longer exists and our phase-2 fat-AAR step dies:
#
#     ./mach gradle geckoview:publishReleasePublicationToMavenLocal
#     > Cannot locate tasks that match
#       'geckoview:publishReleasePublicationToMavenLocal' as task
#       'publishReleasePublicationToMavenLocal' not found in project ':geckoview'.
#
# (Symptom seen on 152->153: the compile + `GeckoView version = 153.0.<buildid>`
# succeed, then the publish step alone fails on the missing task.)
#
# FIX: re-add a POM-ONLY `release` publication that reproduces the 151/152
# behaviour EXACTLY (see CLAUDE.md "Build / publish mechanics", phase 2). It
# attaches ONLY the release sources + javadoc jars — the per-variant
# `sourcesJarRelease` / `javadocJarRelease` tasks that
# `androidComponents.onVariants(selector().all())` still registers for the
# release variant — and deliberately does NOT use `from components.release`.
# Consequences, all of them load-bearing for 04-build.sh:
#   - maven-publish installs POM + sources + javadoc and NO main `.aar`; with no
#     main artifact attached it stamps `<packaging>pom</packaging>`. That is the
#     precise state 04-build.sh's three-step dance expects: it cp's the assembled
#     fat AAR into ~/.m2 as `<artifactId>-<ver>.aar`, rewrites packaging
#     pom -> aar, and injects the curated transitive deps into the POM.
#   - no `from components.release` => maven-publish emits NO Gradle Module
#     Metadata (`.module`). CLAUDE.md relies on "no .module is produced, so the
#     POM is authoritative"; a `.module` would override our hand-authored POM
#     (packaging + injected deps) and re-break app resolution. Attaching the
#     component would ALSO bundle the plain release aar here, defeating the fat
#     merge that only assembleRelease (with MOZ_ANDROID_FAT_AAR_*) produces.
#   - `artifactId = computeArtifactId()` matches upstream's own debug block, so
#     the coordinate is identical to what 05-sync/04-build read back (geckoview
#     in our --enable-geckoview-lite build); no hardcoding.
#
# Cannot be done from the mozconfig or app side: it is a change to GeckoView's
# own gradle publication wiring.
#
# Idempotent (guarded by the marker AND a runtime findByName) + marker-gated.
# Fails LOUDLY if the debug-publication anchor moved — on a Firefox bump that is
# the signal to re-verify the publishing structure, not to relax the check.
set -euo pipefail

SRC="${1:?usage: 0009-restore-release-publication.sh <gecko-src-root>}"
F="$SRC/mobile/android/geckoview/build.gradle"
MARKER="FIREDOWN-RELEASE-PUBLICATION"

if [ ! -f "$F" ]; then
  echo "ERROR(0009): $F not found — source layout changed for this version." >&2
  exit 1
fi
if grep -q "$MARKER" "$F"; then
  echo "[skip] 0009 release publication already restored"
  exit 0
fi

# Anchor: the upstream debug-only publication. Its presence proves the file still
# uses maven-publish + the `publishing.publications` DSL we are extending; its
# ABSENCE means upstream reworked publishing again and this patch must be
# re-verified rather than blindly appended.
if ! grep -q "publishing.publications.create('debug', MavenPublication)" "$F"; then
  echo "ERROR(0009): debug-publication anchor not found in geckoview/build.gradle" >&2
  echo "            — the publishing block was reworked; inspect it and update" >&2
  echo "            this patch (does 'release' need to be restored differently?)." >&2
  exit 1
fi

cat >> "$F" <<'GRADLE'

// FIREDOWN-RELEASE-PUBLICATION: FF153 dropped the upstream `release` publication
// (geckoview now publishes debug-only), which removed the
// `publishReleasePublicationToMavenLocal` task our phase-2 fat-AAR step drives.
// Restore a POM-only release publication so that task exists again and behaves
// exactly as 151/152 did: POM + sources + javadoc, no main .aar (packaging
// stamped `pom`), and no Gradle `.module` metadata — the contract 04-build.sh's
// cp-AAR / rewrite-packaging / inject-deps dance depends on. See firedown patch
// 0009 for the full rationale (do NOT switch this to `from components.release`:
// that would attach the plain release aar and emit a `.module` that overrides
// our hand-authored POM).
afterEvaluate {
    if (!publishing.publications.findByName('release')) {
        publishing.publications.create('release', MavenPublication) {
            artifactId = computeArtifactId()

            pom {
                url = 'https://geckoview.dev'

                licenses {
                    license {
                        name = 'The Mozilla Public License, v. 2.0'
                        url = 'http://mozilla.org/MPL/2.0/'
                        distribution = 'repo'
                    }
                }
            }

            // Sources + javadoc only (registered per-variant by the onVariants
            // factory above). No `from components.release` — see the note above.
            artifact tasks.named("javadocJarRelease")
            artifact tasks.named("sourcesJarRelease")
        }
    }
}
GRADLE

echo "[ok] 0009 restored POM-only release publication (publishReleasePublicationToMavenLocal)"
