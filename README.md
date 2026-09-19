# Universal Controller

Universal Controller is a Mac and iPhone app for creating custom controllers for the app you're using. See [PLAN.md](PLAN.md) for the MVP architecture and implementation order.

## Current Mac shell

Open `UniversalController.xcodeproj` in Xcode and run the `UniversalControllerMac` scheme. The app has no Dock icon: click its game controller icon in the menu bar to open a centered overlay. The overlay shows the app that was frontmost and, when Accessibility access is available, its focused window title. Press Escape, click outside, or click the menu-bar icon again to close it.

To show window titles and use the local Keynote action, grant Universal Controller access in **System Settings → Privacy & Security → Accessibility**. With Keynote open, click the menu-bar icon and use **Next Slide** to send Right Arrow to Keynote. The overlay closes before sending the key and checks that Keynote is frontmost. Controller generation and phone pairing are planned but not connected yet.

For command-line builds, use `xcodebuild -project UniversalController.xcodeproj -scheme UniversalControllerMac -configuration Debug -derivedDataPath DerivedData build`. Keep code signing enabled so the bundle identifier is included in the app signature. Quit and reopen the app after rebuilding; it does not reload Swift changes while running. This project currently uses ad hoc signing, so macOS may ask for Accessibility access again after a rebuild. An Apple Development signing certificate can make that permission more stable.
