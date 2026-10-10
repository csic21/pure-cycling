# 0.1.19 audit remediation

## Deployment boundary

The app binds newly created rides/routes and every outbox operation to the account at creation. Existing unassigned records stay local until the rider explicitly assigns them in Settings → Cloud sync. Changing accounts never transfers an existing owner's records. Offline records and account RLS remain intact.

Migration `20261010082529_scrub_ride_tombstones.sql` is prepared for a separately approved backend deployment. It scrubs coordinates/descriptions from future ride tombstones and distinguishes omitted geometry from explicit JSON null. It preserves the opaque GPX object reference until Storage cleanup and keeps existing invoker/RLS/conflict rules. It does not purge historical tombstones or actual Storage data. Publishing this APK does not deploy that migration; complete cloud-side tombstone scrubbing requires the approved migration.

Synthetic regression coverage runs against in-memory SQLite, temporary export directories, fake authenticated HTTP transports, mock platform channels, and disposable Supabase Postgres containers. No real accounts, locations, or production data are used.

## Android supply chain

Gradle is pinned to 8.14.4 with the official distribution SHA-256 from https://services.gradle.org/distributions/gradle-8.14.4-all.zip.sha256. The [8.14.4 release notes](https://docs.gradle.org/8.14.4/release-notes.html) document both repository-failure vulnerabilities fixed by this patch. Android/AndroidX/Google Android dependency groups are scoped to Google Maven; Kotlin plugin resolution is scoped in the plugin portal. Flutter's own pinned engine repository remains controlled by Flutter 3.41.9.

The Gradle distribution checksum and committed pub/npm locks are checked; full Gradle dependency-verification metadata is not claimed. Generating verification metadata from one unreviewed CI download would establish trust in that download rather than independently verify it. Repository filtering, the patched resolver, and Android CI are the immediate controls; a reviewed dependency-checksum inventory remains a separate hardening exercise.

Legacy tag-triggered release publication is retired. `.github/release-request.json` on main is the sole publication route, with source/tag equality, package/version inspection, monotonically increasing versionCode, signer continuity, public APK hash, and published retry guards.

## Verification limits

Device-specific GNSS, real screen-off foreground-service behavior, mounted-phone orientation, battery consumption and UI frame latency still require physical-device measurements. This release does not claim such measurements. Existing compass/orientation logic is preserved.
