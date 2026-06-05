// FIREDOWN-GECKO-PREFS  (marker line — do not delete; the applier keys on it)
//
// Default prefs baked into the Firedown GeckoView build. scripts/03-apply-patches
// appends this block to mobile/android/app/geckoview-prefs.js. These are
// *defaults*: Firedown's GeckoPreferenceController can still override any of them
// at runtime, so nothing here hard-conflicts with app-side settings.
//
// Unknown prefs are harmless — pref() just stores a value nothing reads. The
// Pocket/activity-stream entries are mostly Fenix-UI prefs absent from a bare
// GeckoView/Firedown; they're included defensively (engine-level off).

// ---- DRM / EME off ----------------------------------------------------------
pref("media.eme.enabled", false);
pref("media.gmp-widevinecdm.enabled", false);
pref("media.gmp-widevinecdm.visible", false);
pref("media.gmp-manager.updateEnabled", false);

// ---- Telemetry / data reporting off -----------------------------------------
pref("toolkit.telemetry.enabled", false);
pref("toolkit.telemetry.unified", false);
pref("toolkit.telemetry.server", "data:,");
pref("toolkit.telemetry.archive.enabled", false);
pref("toolkit.telemetry.newProfilePing.enabled", false);
pref("toolkit.telemetry.updatePing.enabled", false);
pref("toolkit.telemetry.bhrPing.enabled", false);
pref("toolkit.telemetry.firstShutdownPing.enabled", false);
pref("toolkit.telemetry.shutdownPingSender.enabled", false);
pref("toolkit.telemetry.coverage.opt-out", true);
pref("toolkit.coverage.opt-out", true);
pref("toolkit.coverage.endpoint.base", "");
pref("datareporting.healthreport.uploadEnabled", false);
pref("datareporting.policy.dataSubmissionEnabled", false);
pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
pref("app.shield.optoutstudies.enabled", false);
pref("app.normandy.enabled", false);
pref("app.normandy.api_url", "");
pref("messaging-system.rsexperimentloader.enabled", false);
pref("breakpad.reportURL", "");
pref("browser.tabs.crashReporting.sendReport", false);

// ---- Pocket / sponsored (mostly Fenix-layer; engine defaults off) -----------
pref("extensions.pocket.enabled", false);
pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
pref("browser.newtabpage.activity-stream.showSponsored", false);
pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
pref("browser.newtabpage.activity-stream.telemetry", false);

// ---- Hardened privacy defaults (IronFox-style) ------------------------------
pref("privacy.query_stripping.enabled", true);
pref("privacy.query_stripping.enabled.pbmode", true);
pref("privacy.donottrackheader.enabled", true);
pref("privacy.globalprivacycontrol.enabled", true);
pref("privacy.globalprivacycontrol.functionality.enabled", true);
pref("privacy.partition.network_state", true);
pref("network.http.referer.defaultPolicy", 2);
pref("network.http.referer.defaultPolicy.pbmode", 2);
pref("network.http.referer.XOriginTrimmingPolicy", 2);
pref("beacon.enabled", false);
pref("network.dns.disablePrefetch", true);
pref("network.predictor.enabled", false);
pref("network.prefetch-next", false);
pref("network.IDN_show_punycode", true);
// Limit WebRTC local-IP exposure without breaking calls outright.
pref("media.peerconnection.ice.default_address_only", true);

// ---- Aggressive toggles left OFF by default ---------------------------------
// HTTPS-only can break some sites and a few media-capture flows, so it ships
// off; uncomment if you want it as the default.
// pref("dom.security.https_only_mode", true);
pref("dom.security.https_only_mode_pbm", true);

// ---- IronFox-derived: connection / add-on probe hardening -------------------
// Near-zero site-behaviour impact; pure attack-surface / fingerprint reduction.
// IronFox disables speculative connections with a code patch
// (geckoview-disable-speculative-connections.patch); the pref expresses the
// same thing without a source diff. The mozAddonManager pair stops a remote
// page from probing or triggering add-on installs (note:
// block_mozAddonManager does NOT enable global resistFingerprinting despite the
// pref prefix — it's a standalone toggle).
pref("network.http.speculative-parallel-limit", 0);
pref("extensions.webapi.enabled", false);
pref("privacy.resistFingerprinting.block_mozAddonManager", true);

// ---- IronFox-derived: silence Mozilla phone-home endpoints ------------------
// These stop background pings to Mozilla services that a no-telemetry build has
// no use for. Tradeoff: with the captive-portal/connectivity service off, a
// hotspot login page won't auto-pop — opening any http URL still triggers it.
// Kept as defaults (runtime-overridable) so a user who needs captive-portal
// auto-detect can flip it back.
pref("network.connectivity-service.enabled", false);
pref("network.captive-portal-service.enabled", false);
pref("captivedetect.canonicalURL", "");
pref("browser.region.network.url", "");
pref("browser.region.update.enabled", false);
pref("extensions.getAddons.cache.enabled", false);
// FIREDOWN-GECKO-PREFS-END
