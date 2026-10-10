# 0.1.19 audit remediation

## Deployment boundary

The app binds newly created rides/routes and every outbox operation to the account at creation. Existing unassigned records stay local until the rider explicitly assigns them in Settings → Cloud sync. Changing accounts never transfers an existing owner's records. Offline records and account RLS remain intact.

Migration `20261010085644_scrub_ride_tombstones.sql` was deployed after independent review and migration CI on 2026-10-10. Its filename matches the deployment version assigned by Supabase. It clears precise coordinates and free text from future accepted ride tombstones and distinguishes omitted geometry from explicit JSON null. Activity metrics, timestamps and the opaque GPX cleanup reference remain. Post-deployment catalog checks verified the exact reviewed function body, SECURITY INVOKER (`security_definer=false`), unchanged search path and grants; security/performance advisors were unchanged. Existing RLS and conflict rules remain intact. No historical tombstone rows or actual Storage objects were purged.

Synthetic regression coverage runs against in-memory SQLite, temporary export directories, fake authenticated HTTP transports, mock platform channels, and disposable Supabase Postgres containers. No real accounts, locations, or production data are used.

## GPX input budget

Files and cloud GPX downloads are stream-limited to 16 MiB; clipboard text uses the same UTF-8 byte budget. The pull parser rejects DTD/custom entities, nesting deeper than 32, metadata text over 16,384 characters, and more than 100,000 incoming points (including malformed/discarded points). Parsing and route construction run in a worker isolate, and saving reuses the validated preview model. These are tested resource bounds, not device-specific frame-rate or memory benchmarks.

## Android supply chain

Gradle is pinned to 8.14.4 with the official distribution SHA-256 from https://services.gradle.org/distributions/gradle-8.14.4-all.zip.sha256. The [8.14.4 release notes](https://docs.gradle.org/8.14.4/release-notes.html) document both repository-failure vulnerabilities fixed by this patch. Android/AndroidX/Google Android dependency groups are scoped to Google Maven; Kotlin plugin resolution is scoped in the plugin portal. Flutter's own pinned engine repository remains controlled by Flutter 3.41.9.

The Gradle distribution checksum and committed pub/npm locks are checked; full Gradle dependency-verification metadata is not claimed. Generating verification metadata from one unreviewed CI download would establish trust in that download rather than independently verify it. Repository filtering, the patched resolver, and Android CI are the immediate controls; a reviewed dependency-checksum inventory remains a separate hardening exercise.

Legacy tag-triggered release publication is retired. `.github/release-request.json` on main is the sole publication route, with source/tag equality, package/version inspection, monotonically increasing versionCode, signer continuity, public APK hash, and published retry guards.

## Verification limits

Device-specific GNSS, real screen-off foreground-service behavior, mounted-phone orientation, battery consumption and UI frame latency still require physical-device measurements. This release does not claim such measurements. Existing compass/orientation logic is preserved.
