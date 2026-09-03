# F1 Live for macOS

A native macOS menu-bar port of [marconn01/live-f1](https://github.com/marconn01/live-f1). It keeps the original plugin's at-a-glance race weekend dashboard while replacing its Omarchy/QML integrations with SwiftUI, Notification Center, and the macOS cache directory.

## Features

- Menu-bar countdown to the next session, with a live indicator during sessions
- Next race, local-time weekend schedule, circuit map, qualifying grid, upcoming races, and driver standings
- Top-five standings plus any number of favorite drivers, with Lewis Hamilton selected by default on first launch
- OpenF1 live timing tower with positions, intervals, gaps, laps, pit-stop counts, and race-control status
- Delayed-feed warnings that preserve the last known timing while data is unavailable
- Offline fallback from `~/Library/Caches/F1Live`
- Opt-in session reminders with clear macOS permission status
- Optional Open at Login setting to start the menu-bar app when you sign in
- Secure in-app update checks with optional automatic download and installation
- Report a Bug shortcut that opens a draft on GitHub
- No API key required

## Requirements

- macOS 14 Sonoma or later

## Download and install

Download the newest universal ZIP from [GitHub Releases](https://github.com/johndavidwright/f1-live-macos/releases/latest), then follow [INSTALL.md](INSTALL.md). The app is menu-bar-only, so it does not appear in the Dock. Open its gear button to enable Open at Login, choose favorite drivers, configure updates, or change the time format, refresh cadence, and notification rules. Open at Login is off by default; you can also manage it in macOS System Settings under Login Items.

This preview release is ad-hoc signed rather than notarized. See [INSTALL.md](INSTALL.md) for the one-time macOS approval flow.

Development and release commands are documented separately in [DEVELOPMENT.md](DEVELOPMENT.md).

## Data and privacy

Race data comes from the public, keyless [Jolpica-F1](https://jolpi.ca/) and [OpenF1](https://openf1.org/) APIs. Calendar and standings responses are cached locally so the dashboard can continue to show its last good data offline. Live timing is polled only while live mode is enabled and the schedule indicates an active session. Update checks and downloads contact GitHub and its release-asset hosting.

Session reminders are opt-in for new users. F1 Live explains them before requesting macOS notification permission and preserves existing notification preferences when upgrading. **Report a Bug** opens a GitHub draft containing the app and macOS versions; no logs are attached and no issue is submitted automatically.

## Attribution and license

The application logic is a macOS port of `live-f1` and is distributed under its MIT license; see [LICENSE](LICENSE). Circuit maps are by [Jules Roy](https://github.com/julesr0y/f1-circuits-svg), licensed under CC BY 4.0. In-app updates use the MIT-licensed [Sparkle](https://sparkle-project.org/) framework. See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for complete attribution details.

Formula 1 data comes from public APIs. This project is unofficial and is not associated with or endorsed by Formula 1.
