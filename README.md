# F1 Live for macOS

A native macOS menu-bar port of [marconn01/live-f1](https://github.com/marconn01/live-f1). It keeps the original plugin's at-a-glance race weekend dashboard while replacing its Omarchy/QML integrations with SwiftUI, Notification Center, and the macOS cache directory.

## Features

- Menu-bar countdown to the next session, with a live indicator during sessions
- Next race, local-time weekend schedule, circuit map, qualifying grid, upcoming races, and driver standings
- Top-five standings plus any number of favorite drivers, with Lewis Hamilton selected by default on first launch
- OpenF1 live timing tower with positions, intervals, gaps, laps, pit-stop counts, and race-control status
- Offline fallback from `~/Library/Caches/F1Live`
- Native macOS notifications and a settings window
- No API key, third-party package, or background helper required

## Requirements

- macOS 14 Sonoma or later
- Apple Command Line Tools or Xcode with Swift 6

## Build and run

```sh
./scripts/build-app.sh
open "dist/F1 Live.app"
```

The build script produces one universal app containing native Apple-silicon and Intel executables.

To install it for the current user and launch it:

```sh
./scripts/install.sh
```

To create the versioned friends-and-family ZIP and SHA-256 checksum:

```sh
./scripts/package-release.sh
```

That installs the app at `~/Applications/F1 Live.app`. The app is menu-bar-only, so it does not appear in the Dock. Open its gear button to choose favorite drivers or change the time format, refresh cadence, and notification rules. The single-page race view always shows the top five; favorite rows are highlighted, and selected drivers outside the top five are appended to the standings.

For development, `swift run F1Live` also works from the repository root. Run the deterministic model checks and a live API smoke test with `./scripts/test.sh`. The Swift Testing suite runs through `swift test` with a full Xcode installation and in the included GitHub Actions workflow; Command Line Tools alone can compile that suite but does not include Apple's test-bundle runner.

This preview release is ad-hoc signed rather than notarized. See [INSTALL.md](INSTALL.md) for the one-time macOS approval flow.

## Data and privacy

F1 Live connects only to the public, keyless [Jolpica-F1](https://jolpi.ca/) and [OpenF1](https://openf1.org/) APIs. Calendar and standings responses are cached locally so the dashboard can continue to show its last good data offline. Live timing is polled only while live mode is enabled and the schedule indicates an active session.

## Attribution and license

The application logic is a macOS port of `live-f1` and is distributed under its MIT license; see [LICENSE](LICENSE). Circuit maps are by [Jules Roy](https://github.com/julesr0y/f1-circuits-svg), licensed under CC BY 4.0; see [CIRCUITS-LICENSE.txt](CIRCUITS-LICENSE.txt) and [ATTRIBUTIONS.md](ATTRIBUTIONS.md).

Formula 1 data comes from public APIs. This project is unofficial and is not associated with or endorsed by Formula 1.
