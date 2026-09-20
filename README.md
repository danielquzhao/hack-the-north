# Universal Controller

Universal Controller is a Mac and iPhone app for creating custom controllers for the app you're using. See [PLAN.md](PLAN.md) for the MVP architecture and implementation order.

## Current Mac shell

Open `UniversalController.xcodeproj` in Xcode and run the `UniversalControllerMac` scheme. The app has no Dock icon: click its game controller icon in the menu bar to open a centered overlay. The overlay shows the app that was frontmost and, when Accessibility access is available, its focused window title. Press Escape, click outside, or click the menu-bar icon again to close it.

To show window titles and use the local Keynote action, grant Universal Controller access in **System Settings → Privacy & Security → Accessibility**. With Keynote open, click the menu-bar icon and use **Next Slide** to send Right Arrow to Keynote. The overlay closes before sending the key and checks that Keynote is frontmost.

For local builds, create an ignored `LocalSigning.xcconfig` at the repository root. Set `DEVELOPMENT_TEAM = YOUR_TEAM_ID`, `CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development`, and `PHONE_BUNDLE_IDENTIFIER = com.yourname.universalcontroller.phone` on separate lines. Choose a phone bundle identifier that Apple can register to your team. Xcode reads this file through `SharedSigning.xcconfig`, so your personal team and phone identifier do not need to be committed. For command-line Mac builds, use `xcodebuild -project UniversalController.xcodeproj -scheme UniversalControllerMac -configuration Debug -xcconfig LocalSigning.xcconfig -derivedDataPath DerivedData build`. Quit and reopen the app after rebuilding; it does not reload Swift changes while running. Signing with the same Apple Development identity helps macOS keep Accessibility and keyboard event permissions across rebuilds.

Sending Right Arrow with Core Graphics also requires macOS keyboard event (`PostEvent`) access. If **Request Keyboard Access** shows no system prompt, `tccutil reset PostEvent dev.universalcontroller.mac` clears the remembered decision for this app. Relaunch the app and request access again. Set up Apple Development signing before further rebuilds to avoid invalidating grants with each code change.

## Pair an iPhone

Open Keynote, run `UniversalControllerMac`, and open the menu-bar overlay. Describe a controller and click **Generate Controller**, or choose a demo layout. Use the Mac preview to select controls, reorder them, change their width and height, edit labels and button styles, and adjust keyboard or pointer mappings. Review the action mapping list, then click **Pair iPhone** when the draft is ready. The Mac validates that draft, advertises a temporary Bonjour service, and displays a QR code that expires after five minutes. The phone receives the edited `ControllerDocument` after pairing. Draft edits persist if you close and reopen the overlay while using the same target app.

Generation uses the [OpenAI Responses API](https://developers.openai.com/api/docs/guides/structured-outputs) with structured output and an [image input](https://developers.openai.com/api/docs/guides/images-vision). Create an [OpenAI API key](https://platform.openai.com/api-keys), paste it into the Mac overlay, and click **Save Key**. The key is stored in your Mac's Keychain, is never added to the repository, and is sent to OpenAI only when you request generation. Each generation request captures only the selected app window, then sends its JPEG image, your description, the app name, bundle ID, and window title to OpenAI. No screenshot is saved to disk. The model can choose only the currently implemented buttons, thumbstick, phone tilt, keyboard shortcuts, and pointer movement. The Mac assigns the controller ID and target app, validates the output, and retries once if the draft is invalid. A failed request leaves the current draft intact; you can still use the labeled demo layout. The model is not involved when you use the controller on the phone.

The first screenshot requires **System Settings → Privacy & Security → Screen & System Audio Recording** permission for Universal Controller. Click **Generate Controller** to trigger macOS's permission request, grant access, then quit and reopen the Mac app before generating again. If more than one window from the captured app is open and the focused window cannot be identified, generation stops rather than sending an unrelated window.

Choose **Presenter** for a Next Slide button and swipe pad. Choose **Gamepad** to preview a thumbstick and A/B/X/Y button faces. The sample maps A to next slide, B to previous slide, X to black screen, Y to advance, and the thumbstick to pointer movement. **Phone tilt moves pointer** adds an optional motion control. The phone reads motion only while that control is visible; tap its card to recenter. Choose **Gestures** to try separate swipe, pinch, and rotation pads. These are built-in demo layouts; generating from a prompt creates a separate editable draft.

Swipe left or up on the **Presenter** pad for the next slide and right or down for the previous slide. Pinch in/out and two-finger clockwise/counterclockwise rotation on the **Gestures** demo pads also send one action when each gesture ends. The Mac editor gives every direction its own keyboard mapping. AI can generate any of these pads from a request. Gestures are recognized only within their pads, so they do not interfere with buttons or the thumbstick. Rebuild both apps after this schema and pairing-protocol change before pairing again.

On a physical iPhone:

1. Run the `UniversalControllerPhone` scheme.
2. Tap **Scan Mac QR**.
3. Allow Camera and Local Network access.
4. Scan the QR displayed by the Mac.
5. Keep both apps open until the phone shows the controller and the Mac shows **Connected**.

The phone authenticates with the one-time secret in the QR and automatically sends a ping. **Bidirectional connection verified** on the Mac confirms that messages work in both directions. Once paired, the phone uses the available screen for controls, with a compact title and disconnect button at the top.

Disconnecting on either device clears the paired state on the other. If a device quits or the connection closes unexpectedly, the other device reports the lost connection so you can pair again.

To test the complete path, start a Keynote slideshow and tap **Next Slide** on the paired iPhone. The phone emits a generic control event; the Mac validates its controller ID, revision, event type, value type, and sequence, resolves the binding through `ControllerActionRouter`, activates the captured Keynote app, and executes the pre-coded Right Arrow action. If permissions are missing or Keynote has quit, the Mac overlay shows the error.

QR scanning requires a physical iPhone. The simulator can build and display the pairing screen, but VisionKit does not provide camera scanning there. Both devices should be on the same Wi-Fi network; the Network framework configuration also opts into Apple peer-to-peer networking.
