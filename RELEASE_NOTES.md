# F1 Live 0.2.7

Preview release for macOS 14 or later, supporting Apple-silicon and Intel Macs.

## Highlights

- Fixes the menu bar staying at “0m” after a race. It now counts down to the next scheduled session and names that session in the tooltip. When no future session is scheduled, it shows “F1”.
- Shows the finished race in the dashboard for 30 minutes, then automatically switches to the next weekend without waiting for a refresh.
- Keeps delayed and red-flagged races visible while live timing confirms they are still running. When a finish signal is available, the 30-minute window follows the actual finish.

F1 Live remains free. The calendar, standings, circuit maps, qualifying results, countdowns, Fantasy deadlines, and reminders work without an OpenF1 account. OpenF1 subscriptions are managed directly by OpenF1.

If you have version 0.2.0 or later, choose **Check for Updates…** in F1 Live to download and install this release. New users and users on 0.1.0 can install the universal ZIP using `INSTALL.md`.

## Known limitation

This preview is ad-hoc signed and not notarized. Follow `INSTALL.md` to approve its first launch through macOS Privacy & Security. Updates may require renewed access to saved OpenF1 credentials through **Authorize Saved Credentials** in Settings.
