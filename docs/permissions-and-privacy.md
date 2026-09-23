# Permissions and privacy configuration

Build 1.0 (14), updated September 8, 2026 for the fixed HTTPS endpoint. This is the minimum set for the
implemented features, not an App Store approval guarantee.

## User-facing permission requests

- **Location while using the app:** selects a regional forecast through the
  Weather Atlas HTTPS service and centers the weather map when requested. Approximate
  location is the default (`NSLocationDefaultAccuracyReduced = true`). No Always,
  temporary full-accuracy, background-location or widget-location request exists.
  Denying location still allows the default town (initially Halifax) or a manual
  map selection. Turning forecast following off keeps the current region.
- **No Local Network request:** the app and widget now use the fixed public
  service at `https://weatheratlas.ioresearch.ca`. The former local-network
  purpose string is removed along with server configuration.

Updating the app does not reset an existing permission decision or force another
system prompt. The new version does not reset any existing privacy decision.

Ordinary public internet access has no separate iOS permission prompt. No camera,
microphone, photos, contacts, Bluetooth, tracking, notification, motion, health
or speech permission is declared or requested. On-device forecast summaries do
not require any of those permissions.

## Capabilities and transport

The only explicit signing entitlement in the project is
`group.com.ior.weatheratlas` under App Groups, shared with the forecast widget.
It is required to exchange settings and forecast snapshots. There are no push,
iCloud, background-task, Wi-Fi-information, multicast or network-extension
capabilities. Normal signed builds also have Xcode's identity/team entitlements;
development builds have debugger access, which is not a user permission.

Both targets now use default App Transport Security without any HTTP,
local-network, arbitrary-load, media/web-content or TLS-weakening exceptions.
Release builds use only the canonical HTTPS service, including when old
preferences or widget settings contain a different address. The narrowly scoped
Debug-simulator fixture hook is documented in
[fixed HTTPS endpoint](fixed-https-endpoint.md); it does not ship in Release.

## Privacy manifest and submission checks

The app bundles `Resources/PrivacyInfo.xcprivacy`, declaring no tracking and only
the required `UserDefaults` reason **CA92.1** for app-local settings, saved
selections and forecast snapshots. The widget shares JSON files through the
App Group, not UserDefaults, so it does not acquire an unused UserDefaults reason.
No unrelated required-reason API category is added.

This manifest records tracking and required-reason API use; it does not assert an
empty collected-data list. It does **not** complete the App Store Connect privacy answers.
Before submission, verify the actual deployed server's retention/access logging:
coordinate lookups and map requests send locations to that server, and access
logs can retain query strings and client IP addresses. Do not claim that no data
is collected without auditing that deployment. Supply an accurate privacy policy
and privacy labels. Reviewers also need a reachable server or a documented review
setup. The fixed public HTTPS endpoint replaces the private `.iolan` address;
the app no longer requires an insecure-HTTP exception justification.

Sources: Apple's [location accuracy setting](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationdefaultaccuracyreduced),
[local-network privacy guide](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy),
[required-reason API list](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
and [HTTP exception review requirements](https://developer.apple.com/documentation/bundleresources/information-property-list/nsexceptionallowsinsecurehttploads).

## Historical build 12 verification

All 141 unit tests passed, including four new packaged-configuration checks for
both targets and the app's privacy manifest. Two simulator UI scenarios passed:
granting location and toggling following off/on with persistence, and denying
location with Halifax fallback and manual town selection. The simulator's
permission prompt screenshot was inspected separately: it explicitly asks
for approximate location, explains the server use, and offers only Allow Once,
Allow While Using App and Don't Allow. The unsigned Release
iOS build and signed Debug device build succeeded. Release resources and both
signed development entitlements were inspected: only the intended App Group plus
normal identity/team/debugger entries are present. Xcode's pre-existing iPad
orientation warning remains outside this permissions change.

Build 12 and its widget were installed on the connected iPhone at 09:34 Halifax
time on September 8. No physical-device UI automation was run; existing phone
privacy choices were not reset. No backend change or restart was needed.
