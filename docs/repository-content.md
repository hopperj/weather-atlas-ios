# iOS repository contents

Commit the app's source and reproducible project inputs, not the output of a
particular developer's build or App Store upload. The root `.gitignore` implements
this policy without deleting any local files.

## Included

- `WeatherAtlas`, `Shared`, and `WeatherAtlasWidgets`: Swift source, bundled
  coastline data, attribution, asset catalogs/icons, Info.plists, entitlements,
  and the privacy manifest.
- `WeatherAtlas.xcodeproj`: the project, workspace definition, and shared scheme.
  These are intentionally committed so a fresh clone opens directly in Xcode.
- `project.yml`: the XcodeGen definition used to regenerate the project.
- Unit/UI tests and the `Support` fixture server and benchmark source.
- Documentation, including screenshot-generation instructions.
- Any dependency manifests/lockfiles added later, including `Package.resolved`,
  `Podfile.lock`, and `Cartfile.resolved`; installed dependencies are not committed.
- Sanitized environment/configuration examples and shared editor configuration.

The development team identifier and bundle identifiers in the project are not
private signing credentials. Keep them with the entitlements/project configuration;
actual keys, certificates and provisioning profiles stay outside Git.

## Excluded

- `.build`, DerivedData, compiled app bundles, archive/export directories, IPA
  packages, debug symbols, test results, profiler output, caches and logs.
- Xcode's per-user workspace settings, editor backups and OS metadata.
- Real environment files, private keys, App Store Connect signing keys,
  certificates, provisioning profiles and local `ExportOptions.plist` files.
- Generated images/ZIPs under `Screenshots` (its README files remain included),
  generated fastlane reports/screenshots, and loose `Codex Image*.png` drafts.
  The actual icon inside `Assets.xcassets` remains included.

The ignore rules deliberately do not exclude all `.plist`, `.json`, `.png`,
`.xcconfig`, `.xcworkspace`, or `.xcodeproj` files: these can be required project
inputs. Future binary dependencies should be managed deliberately, not hidden by
a blanket framework ignore rule.

## Before committing

```bash
git status --short
git add --dry-run .
git ls-files -ci --exclude-standard
```

Review staged changes for credentials as well as unwanted artifacts. Ignore rules
do not detect secrets embedded in source and do not untrack previously committed
files or remove them from history. Never commit signing material to make another
machine's build work; configure signing through Xcode and the appropriate account.
