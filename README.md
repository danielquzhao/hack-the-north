# Universal Controller

Universal Controller is a Mac and iPhone app for creating custom controllers for the app you're using. See [PLAN.md](PLAN.md) for the MVP architecture and implementation order.

## Current Mac shell

Open `UniversalController.xcodeproj` in Xcode and run the `UniversalControllerMac` scheme. The app has no Dock icon: click its game controller icon in the menu bar to open a centered overlay. The overlay shows the app that was frontmost and, when Accessibility access is available, its focused window title. Press Escape, click outside, or click the menu-bar icon again to close it.

To show window titles, grant Universal Controller access in **System Settings → Privacy & Security → Accessibility**. Controller generation and phone pairing are planned but not connected yet.
