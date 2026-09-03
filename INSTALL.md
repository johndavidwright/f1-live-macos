# Installing F1 Live 0.2.3

F1 Live requires macOS 14 Sonoma or later and supports both Apple-silicon and Intel Macs.

1. Unzip `F1-Live-0.2.3-macOS-universal.zip`.
2. Move `F1 Live.app` from the extracted folder into Applications.
3. Control-click or right-click `F1 Live.app`, choose **Open**, then confirm **Open**. F1 Live is a menu-bar app, so it will not appear in the Dock.
4. If macOS does not offer the second **Open** button, try launching the app once, then open **System Settings → Privacy & Security**, scroll to Security, click **Open Anyway**, authenticate, and confirm **Open**. macOS should remember the exception for that build.

To verify the download before opening it, put the ZIP and checksum file in the same folder and run:

```sh
shasum -a 256 -c F1-Live-0.2.3-macOS-universal.zip.sha256
```

Only continue if the result says `OK`. Do not disable Gatekeeper globally.

If you already have F1 Live 0.2.0 or later, choose **Check for Updates…** in the app to download and install this release. Version 0.1.0 requires a manual installation.

To start F1 Live automatically when you sign in, open its gear button and enable **General → Open at Login**. This setting is off by default.

Reminders are optional. To enable them, open **Settings → Notifications** and turn on a reminder switch. macOS asks for permission the first time; new installations do not ask for notification access on launch.

To show the clickable Fantasy Lock label beside Qualifying or Sprint without notifications, enable **Settings → Display → Show F1 Fantasy deadline**. Fantasy notifications are a separate option under **Notifications**.

Found a problem? Choose **Settings → Help → Report a Bug…** to open an editable GitHub issue draft with the app and macOS versions. Nothing is submitted until you submit the issue yourself.
