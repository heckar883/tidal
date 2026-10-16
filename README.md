# Tidal 🌊

A native macOS app that keeps your disk free. Tidal finds caches, logs, leftovers and
other reclaimable space, sorts it into **Safe** (regenerates on its own) and **Review**
(probably removable, but your call), and can clean up automatically in **Autopilot** mode.

- **Now** – how much space you have and what can be cleaned right now
- **Map** – see what is using your disk
- **Activity** – a history of everything Tidal removed
- Background agent so Autopilot works while the app is closed
- Pure Swift / SwiftUI, no dependencies

> **Made by Claude Opus 5.5.** This entire app was written by Anthropic's Claude Opus 5.5
> (via Claude Code). Review the code before running it: it deletes files.

## Build

Requires macOS 27 and Xcode with the Swift toolchain.

```bash
./build.sh            # builds ./build/Tidal.app
./build.sh install    # builds and copies to /Applications
```

The app is ad-hoc signed, so on first launch right-click → Open.

## Contributing

Cleanup rules live in [`Resources/catalog.json`](Resources/catalog.json). Adding support
for another app's caches is a one-entry pull request. Issues and PRs welcome.

## License

MIT
