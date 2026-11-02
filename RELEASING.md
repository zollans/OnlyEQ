# Releasing OnlyEQ

OnlyEQ uses Sparkle 2 for signed automatic updates. Releases starting with 1.2.4 use the Ed25519 private key stored in the macOS login Keychain under the account `zollans.OnlyEQ.v2`; never commit or upload an exported private key. The corresponding public key lives in `Resources/Info.plist`.

The original signing key used through 1.2.3 was lost. Version 1.2.4 is therefore a one-time manual bridge release: users on 1.2.3 or earlier must reinstall it manually. It uses the separate `appcast-v2.xml` feed so older clients are not offered an update they cannot verify. Once 1.2.4 is installed, later releases update automatically through the v2 feed.

For each release:

1. Increment both `CFBundleVersion` and `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Add `release-notes/VERSION.md`.
3. Run `./scripts/prepare-release.sh VERSION`.
4. Commit the source changes and generated `appcast-v2.xml`, merge them to `main`, and tag the merged commit as `vVERSION`.
5. Publish `build/OnlyEQ.app.zip` and `appcast-v2.xml` as release assets, using the versioned release-notes file as the GitHub release notes.
6. Run `./scripts/bump-cask.sh VERSION` to point the Homebrew cask in [zollans/homebrew-tap](https://github.com/zollans/homebrew-tap) at the new release. It takes the checksum from GitHub's digest of the uploaded zip, so run it only after the release is published.

Example publishing command after the release commit is on `main`:

```sh
gh release create v1.2.5 \
  build/OnlyEQ.app.zip appcast-v2.xml \
  --title "OnlyEQ 1.2.5" \
  --notes-file release-notes/1.2.5.md \
  --target main
```

The current appcast is served from `https://raw.githubusercontent.com/zollans/OnlyEQ/main/appcast-v2.xml`. Keep the legacy `appcast.xml` frozen at 1.2.3 for clients that still trust the lost key. Update archives must retain the app bundle and Sparkle framework symlinks; `prepare-release.sh` uses `ditto` for that reason.

OnlyEQ is ad-hoc signed rather than Developer ID signed or notarized. Sparkle archive signatures authenticate updates, but losing the Ed25519 private key would require another manual bridge release because Developer ID key rotation is unavailable.
