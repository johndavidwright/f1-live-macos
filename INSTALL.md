# Installing F1 Live 0.2.0

F1 Live requires macOS 14 Sonoma or later and supports both Apple-silicon and Intel Macs.

1. Unzip `F1-Live-0.2.0-macOS-universal.zip`.
2. Move `F1 Live.app` from the extracted folder into Applications.
3. Control-click or right-click `F1 Live.app`, choose **Open**, then confirm **Open**. F1 Live is a menu-bar app, so it will not appear in the Dock.
4. If macOS does not offer the second **Open** button, try launching the app once, then open **System Settings → Privacy & Security**, scroll to Security, click **Open Anyway**, authenticate, and confirm **Open**. macOS should remember the exception for that build.

To verify the download before opening it, put the ZIP and checksum file in the same folder and run:

```sh
shasum -a 256 -c F1-Live-0.2.0-macOS-universal.zip.sha256
```

Only continue if the result says `OK`. Do not disable Gatekeeper globally.

Version 0.2.0 is the first release with in-app updates. After installing it manually, future updates can be checked, downloaded, and installed from F1 Live itself.
