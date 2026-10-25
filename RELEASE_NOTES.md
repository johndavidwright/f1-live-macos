# F1 Live 0.2.6

Preview release for macOS 14 or later, supporting Apple-silicon and Intel Macs.

## Highlights

- Shows every driver's last known position when joining a race midway through, including drivers whose positions have not changed recently. Position updates also recover after sleep or a connection outage.
- Keeps the timing tower updating when pit, driver, lap, interval, or race-control data is temporarily unavailable. A warning identifies the missing data while failed feeds retry independently.
- Uses recognized race-control events for track status, so a steward notice mentioning a safety car cannot replace a red flag. Race-control updates now refresh alongside positions and intervals.
- Keeps live timing available during delayed or red-flagged races and follows the actual finish signal, including a 30-minute window for final updates. The menu-bar live label clears when the race finishes.
- Adds six regression tests and a repeatable live-race diagnostic. Verified during the 2026 United States Grand Prix with all 22 drivers across six polls and timing data 2–3 seconds old.

F1 Live remains free. The calendar, standings, circuit maps, qualifying results, countdowns, Fantasy deadlines, and reminders work without an OpenF1 account. OpenF1 subscriptions are managed directly by OpenF1.

If you have version 0.2.0 or later, choose **Check for Updates…** in F1 Live to download and install this release. New users and users on 0.1.0 can install the universal ZIP using `INSTALL.md`.

## Known limitation

This preview is ad-hoc signed and not notarized. Follow `INSTALL.md` to approve its first launch through macOS Privacy & Security. Updates may require renewed access to saved OpenF1 credentials through **Authorize Saved Credentials** in Settings.
