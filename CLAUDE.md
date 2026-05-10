# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository

Fork of [overtake/TelegramSwift](https://github.com/overtake/TelegramSwift) — the unofficial-but-canonical native Telegram client for macOS. Configured for personal API credentials and a custom bundle ID (`com.n71903.telegram`, team `T34Z9TRYBM`).

The build was successfully run on Xcode 26 against macOS 15+. Several modifications away from upstream were required to make it build on this toolchain — see "Known fork-specific changes" below before assuming an issue is upstream.

## Build commands

The build is **not** a single `xcodebuild` invocation. Native C/C++ dependencies must be built into xcframeworks first, then the Xcode workspace builds the Swift app on top. Order matters.

```bash
# 1. One-time native deps (cmake, ninja, autotools, codecs)
brew install cmake ninja openssl@3 zlib autoconf libtool automake yasm pkg-config nasm meson

# 2. Build native xcframeworks into core-xprojects/<lib>/build
#    (slow: 10–30min; rebuilds everything when scripts/rebuild contains "yes")
sh scripts/configure_frameworks.sh

# 3. Resolve SPM packages (flaky network → may need retry)
xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -resolvePackageDependencies

# 4. Build the app
xcodebuild \
  -workspace Telegram-Mac.xcworkspace \
  -scheme Telegram \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/telegram_derived \
  -allowProvisioningUpdates \
  build
```

`scripts/rebuild` is a flag file: `yes` = nuke `core-xprojects/*/build` and rebuild all native libs; `no` = reuse existing builds. Flip to `yes` only when a native dep's source changed.

Built `.app` lives under the derivedDataPath. The currently-shipped binary is checked out to `bin/Telegram.app`.

Workspace targets:
- `Telegram` — main app (scheme used for builds)
- `TelegramShare` — share extension
- `FocusIntents` — Focus / App Intents extension

Build configurations live in `configurations/*.xcconfig` (Alpha / Beta / Stable / AppStore). `SOURCE` xcconfig var (`DEBUG`/`STABLE`/`APP_STORE`/`BETA`) drives `ApiEnvironment.prefix`, which in turn picks the per-build app-group container directory.

There is no test scheme or test target — this codebase ships without unit tests. Don't synthesize a `xcodebuild test` command.

## Architecture

### Three layers

1. **Native xcframeworks** (`core-xprojects/`, built from sources in `submodules/`): OpenSSL, OpenH264, libopus, libvpx, libwebp, dav1d, mozjpeg, ffmpeg, webrtc, tde2e. Each has its own Xcode project under `core-xprojects/<lib>/<Name>.xcodeproj` that wraps the upstream source tree from `submodules/<lib>` and produces an xcframework. `configure_frameworks.sh` drives them in order, then rsyncs public headers into the SwiftPM packages that depend on them.

2. **Cross-platform Telegram core** (`submodules/telegram-ios/`): a vendored slice of the official iOS repo. Contains `TelegramCore` (MTProto + state machine), `Postbox` (encrypted SQLite-backed store), `SSignalKit` (FRP primitives), media decoders, and FlatBuffers schemas. Code generation: `submodules/telegram-ios/submodules/TelegramCore/FlatSerialization/macOS/generate.sh` (invoked by `configure_frameworks.sh`) regenerates Swift from `.fbs` schemas using the bundled `scripts/flatc`.

3. **macOS app** (`Telegram-Mac/`, ~940 Swift files) plus 50 in-repo SwiftPM packages under `packages/` (UI kit `TGUIKit`, theming `ColorPalette`/`Colors`, `Localization`, media helpers, `ApiCredentials`, etc.). The app target depends on these as local SwiftPM packages declared inside the Xcode project — **not** through a top-level `Package.swift`. To find where a package is consumed, search the `.pbxproj` for `XCSwiftPackageProductDependency`.

### Where to make changes

- **App UI / view controllers / chat features**: `Telegram-Mac/`. Files are flat (no subdirectory hierarchy) — find by grep, not by browsing.
- **Reusable UI components**: `packages/TGUIKit`.
- **Network / Telegram protocol behavior**: `submodules/telegram-ios/submodules/TelegramCore` — but tread carefully, this is upstream-tracked code.
- **Calls / VOIP**: `submodules/tgcalls` (webrtc bridge) + `Telegram-Mac/CallBridge.mm`.

### API credentials & identity

`packages/ApiCredentials/Sources/ApiCredentials/Config.swift` (`ApiEnvironment`) is the single source of truth for `apiId`, `apiHash`, `bundleId`, `teamId`. The app group identifier is derived as `teamId + "." + bundleId`, so changing either requires updating all four `*.entitlements` files in lockstep:
- `Telegram-Mac/Telegram-Mac.entitlements`
- `Telegram-Mac/Telegram-Sandbox.entitlements`
- `TelegramShare/TelegramShare.entitlements`
- `FocusIntents/FocusIntents.entitlements`

The bundle ID also appears in `Telegram-Mac/GoogleService-Info.plist` (Firebase) and is referenced from `Telegram-Mac/LocalAuth.swift` and `Telegram-Mac/CallBridge.mm`. Search the whole repo when changing it.

## Known fork-specific changes (not upstream)

When debugging, remember these deviations from `overtake/TelegramSwift`:

- **Xcode 26 Metal toolchain quirk**: `project.pbxproj` references `$(DT_TOOLCHAIN_DIR)` instead of `$(TOOLCHAIN_DIR)` for `libswiftAppKit.dylib`. In Xcode 26, `$(TOOLCHAIN_DIR)` resolves to the Metal toolchain during certain phases and the linker fails to find Swift stdlibs. Don't revert this.
- **FirebaseAnalytics removed**: The Firebase iOS SDK ships `FirebaseAnalytics.framework` as a flat (iOS-style) bundle, which fails macOS framework validation ("expected `Versions/Current/Resources/Info.plist`"). The `FirebaseAnalytics` package product was removed from `project.pbxproj` (4 entries). Source code only imports `Firebase` and `FirebaseCrashlytics`, so this is safe — but don't add `import FirebaseAnalytics` calls.
- **Resilient native-dep clones**: `core-xprojects/openssl/OpenSSLEncryption/build.sh` and `core-xprojects/OpenH264/OpenH264/build.sh` wrap their internal `git clone` in `until ... done` retry loops to survive flaky networks. The originals fail-fast on a single transient git error.
- **FFmpeg version directory**: A symlink `submodules/telegram-ios/submodules/ffmpeg/Sources/FFMpeg/ffmpeg-7.1 → ffmpeg-7.1.1` was added because the build script expects `ffmpeg-7.1` while the submodule ships `ffmpeg-7.1.1`.
- **`openssl@3` vs `openssl@1.1`**: `INSTALL.md` says `openssl@1.1`, but that's EOL and no longer in Homebrew. Use `openssl@3`.

## Working in this codebase

- `INSTALL.md` is the upstream build doc and is partially out of date for this fork — prefer the commands above when they conflict.
- The `*.swift` files in `Telegram-Mac/` are flat at the top level; navigate by name with grep.
- Submodules are huge. Before making changes inside `submodules/telegram-ios/`, confirm the change really belongs there vs. in `Telegram-Mac/`.
- When SwiftPM resolution fails mid-build with a clone error, retry — the package fetch is the most common failure point and is almost always transient.
