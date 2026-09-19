# Universal Controller

Universal Controller is a Mac and iPhone app for creating custom controllers for the app you're using. See [PLAN.md](PLAN.md) for the MVP architecture and implementation order.

## Current Mac shell

Open `UniversalController.xcodeproj` in Xcode and run the `UniversalControllerMac` scheme. The app has no Dock icon: click its game controller icon in the menu bar to open a centered overlay. The overlay shows the app that was frontmost and, when Accessibility access is available, its focused window title. Press Escape, click outside, or click the menu-bar icon again to close it.

To show window titles and use the local Keynote action, grant Universal Controller access in **System Settings → Privacy & Security → Accessibility**. With Keynote open, click the menu-bar icon and use **Next Slide** to send Right Arrow to Keynote. The overlay closes before sending the key and checks that Keynote is frontmost. AI controller generation is not connected yet.

For local builds, create an ignored `LocalSigning.xcconfig` at the repository root. Set `DEVELOPMENT_TEAM = YOUR_TEAM_ID`, `CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development`, and `PHONE_BUNDLE_IDENTIFIER = com.yourname.universalcontroller.phone` on separate lines. Choose a phone bundle identifier that Apple can register to your team. Xcode reads this file through `SharedSigning.xcconfig`, so your personal team and phone identifier do not need to be committed. For command-line Mac builds, use `xcodebuild -project UniversalController.xcodeproj -scheme UniversalControllerMac -configuration Debug -xcconfig LocalSigning.xcconfig -derivedDataPath DerivedData build`. Quit and reopen the app after rebuilding; it does not reload Swift changes while running. Signing with the same Apple Development identity helps macOS keep Accessibility and keyboard event permissions across rebuilds.

Sending Right Arrow with Core Graphics also requires macOS keyboard event (`PostEvent`) access. If **Request Keyboard Access** shows no system prompt, `tccutil reset PostEvent dev.universalcontroller.mac` clears the remembered decision for this app. Relaunch the app and request access again. Set up Apple Development signing before further rebuilds to avoid invalidating grants with each code change.

## Pair an iPhone

Open Keynote, run `UniversalControllerMac`, open the menu-bar overlay, and click **Pair iPhone**. The Mac advertises a temporary Bonjour service and displays a QR code that expires after five minutes. Pairing from Keynote sends a hardcoded **Next Slide** button to the iPhone.

On a physical iPhone:

1. Run the `UniversalControllerPhone` scheme.
2. Tap **Scan Mac QR**.
3. Allow Camera and Local Network access.
4. Scan the QR displayed by the Mac.
5. Keep both apps open until both devices show **Connected**.

The phone authenticates with the one-time secret in the QR and automatically sends a ping. A round-trip time on the phone and **Bidirectional connection verified** on the Mac confirm that messages work in both directions.

Disconnecting on either device clears the paired state on the other. If a device quits or the connection closes unexpectedly, the other device reports the lost connection so you can pair again.

To test the complete path, start a Keynote slideshow and tap **Next Slide** on the paired iPhone. The Mac activates the Keynote app captured when pairing began and sends Right Arrow. If permissions are missing or Keynote has quit, the Mac overlay shows the error.

QR scanning requires a physical iPhone. The simulator can build and display the pairing screen, but VisionKit does not provide camera scanning there. Both devices should be on the same Wi-Fi network; the Network framework configuration also opts into Apple peer-to-peer networking.
