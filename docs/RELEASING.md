# Releasing

KeyNav is sold through Polar: a 14-day trial, then a $39 license for life. Releases are notarized with a Developer ID.

## Before the first paid release

1. Join the Apple Developer Program, create a **Developer ID Application** certificate (Xcode › Settings › Accounts › Manage Certificates), and store notary credentials: `xcrun notarytool store-credentials keynav-notary --apple-id … --team-id …`.
2. The Polar product (org `keynav`) is a $39 one-time purchase with a license-key benefit limited to 3 activations. Its checkout link, organization ID and benefit ID live in `Store` in `Sources/KeyNav/Licensing.swift`.

## Each release

1. Bump `VERSION` in `scripts/build_app.sh` and add a CHANGELOG entry.
2. `DEVELOPER_ID="Developer ID Application: … (TEAMID)" scripts/release.sh`: tests, signs with the hardened runtime, notarizes, staples, and writes `dist/KeyNav.dmg` (notarized and stapled, with the app inside notarized too) with its SHA-256.
3. Run the hardware checklist in docs/TESTING.md against that build.
4. `scripts/deploy_site.sh` deploys the site to keynav.app on Cloudflare Workers with `dist/KeyNav.dmg` at `/download/KeyNav.dmg` (the old `/download/KeyNav.zip` redirects there) (log in once with `npx wrangler@4 login`).

Releases 0.1.0 to 0.2.4 were published free and ad-hoc signed on GitHub.
