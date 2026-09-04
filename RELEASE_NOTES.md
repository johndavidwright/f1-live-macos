# F1 Live 0.2.4

Preview release for macOS 14 or later, supporting Apple-silicon and Intel Macs.

## Highlights

- Adds optional personal OpenF1 credentials in **Settings → OpenF1 Live Timing**. Enter your Client ID and Client Secret, then choose **Save & Test Connection** to enable timing with your own paid OpenF1 account.
- Stores credentials in macOS Keychain and renews the OpenF1 connection automatically. You can remove saved credentials in Settings at any time.
- Keeps startup and background refreshes quiet. If macOS needs permission to read saved credentials, live timing pauses and Settings offers **Authorize Saved Credentials**. Cancelling keeps your credentials saved.
- Replaces the generic invalid-response error with a clear explanation when OpenF1 requires an account or cannot provide timing. The timing view no longer reports **RUNNING** before any data arrives.
- Automatically switches to race timing only when credentials are available. Credential setup stays in Settings, keeping the timing view focused on the session.

F1 Live remains free. The calendar, standings, circuit maps, qualifying results, countdowns, Fantasy deadlines, and reminders work without an OpenF1 account. OpenF1 subscriptions are managed directly by OpenF1.

If you have version 0.2.0 or later, choose **Check for Updates…** in F1 Live to download and install this release. New users and users on 0.1.0 can install the universal ZIP using `INSTALL.md`.

## Known limitation

This preview is ad-hoc signed and not notarized. Follow `INSTALL.md` to approve its first launch through macOS Privacy & Security. Updates may require renewed access to saved OpenF1 credentials through **Authorize Saved Credentials** in Settings.
