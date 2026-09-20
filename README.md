# aiClicker

aiClicker is a Mac and iPhone app for creating custom controllers for the app you're using. See [PLAN.md](PLAN.md) for the MVP architecture and implementation order.

## Current Mac shell

Open `UniversalController.xcodeproj` in Xcode and run the `UniversalControllerMac` scheme. The app has no Dock icon: click its game controller icon in the menu bar to open a centered overlay. The overlay shows the app that was frontmost and, when Accessibility access is available, its focused window title. Press Escape, click outside, or click the menu-bar icon again to close it.

To show window titles and use the local Keynote action, grant aiClicker access in **System Settings → Privacy & Security → Accessibility**. With Keynote open, click the menu-bar icon and use **Next Slide** to send Right Arrow to Keynote. The overlay closes before sending the key and checks that Keynote is frontmost.

For local builds, create an ignored `LocalSigning.xcconfig` at the repository root. Set `DEVELOPMENT_TEAM = YOUR_TEAM_ID`, `CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development`, and `PHONE_BUNDLE_IDENTIFIER = com.yourname.universalcontroller.phone` on separate lines. Choose a phone bundle identifier that Apple can register to your team. Xcode reads this file through `SharedSigning.xcconfig`, so your personal team and phone identifier do not need to be committed. For command-line Mac builds, use `xcodebuild -project UniversalController.xcodeproj -scheme UniversalControllerMac -configuration Debug -xcconfig LocalSigning.xcconfig -derivedDataPath DerivedData build`. Quit and reopen the app after rebuilding; it does not reload Swift changes while running. Signing with the same Apple Development identity helps macOS keep Accessibility and keyboard event permissions across rebuilds.

Sending Right Arrow with Core Graphics also requires macOS keyboard event (`PostEvent`) access. If **Request Keyboard Access** shows no system prompt, `tccutil reset PostEvent dev.universalcontroller.mac` clears the remembered decision for this app. Relaunch the app and request access again. Set up Apple Development signing before further rebuilds to avoid invalidating grants with each code change.

## Pair an iPhone

Open the target Mac app, run `UniversalControllerMac`, and open the menu-bar overlay. Describe a controller and click **Generate Controller**. The AI chooses the built-in controls, their mappings, the preferred phone orientation, and the layout in each orientation. Use the Mac preview to select controls, reorder them, change their width and height, edit labels and button styles, and adjust keyboard or pointer mappings. Review the action mapping list, then click **Pair iPhone** when the draft is ready. The Mac validates that draft, advertises a temporary Bonjour service, and displays a QR code that expires after five minutes. The phone receives the edited `ControllerDocument` after pairing. Draft edits persist if you close and reopen the overlay while using the same target app.

Generation uses the [OpenAI Responses API](https://developers.openai.com/api/docs/guides/structured-outputs) with structured output and an [image input](https://developers.openai.com/api/docs/guides/images-vision). Create an [OpenAI API key](https://platform.openai.com/api-keys), paste it into the Mac overlay, and click **Save Key**. The key is stored in your Mac's Keychain, is never added to the repository, and is sent to OpenAI only when you request generation. Each generation request captures only the selected app window, then sends its JPEG image, your description, the app name, bundle ID, and window title to OpenAI. No screenshot is saved to disk. The model can choose only the implemented buttons, D-pad, thumbstick, tilt, and drag pad, and their supported keyboard, mouse, or scroll mappings. The Mac assigns the controller ID and target app, validates the output, and retries once if the draft is invalid. A failed request leaves the current draft intact. The model is not involved when you use the controller on the phone.

The first screenshot requires **System Settings → Privacy & Security → Screen & System Audio Recording** permission for aiClicker. Click **Generate Controller** to trigger macOS's permission request, grant access, then quit and reopen the Mac app before generating again. If more than one window from the captured app is open and the focused window cannot be identified, generation stops rather than sending an unrelated window.

The available controls are implemented in the app; the AI selects and arranges them. You can request a presentation controller, gamepad buttons, a four-direction D-pad with independently mapped shortcuts, a thumbstick, tilt, or drag pad. The AI can map a thumbstick either to Mac pointer motion or to four directional keyboard shortcuts, such as WASD or arrow keys. A directional thumbstick holds its keys while tilted, supports diagonals, and releases them when centered. Hold a D-pad direction to hold its mapped key; slide to another direction to switch keys. The single drag pad holds a configurable left, right, or middle Mac mouse button while you move one finger and scrolls continuously as you pinch with two fingers. For Google Earth, use a left drag and pinch to zoom; for Blender viewport orbit, use a middle drag and pinch to zoom. Set the Mac pointer over the target viewport before using the pad. The Mac editor lets you change the thumbstick mode and shortcuts, D-pad shortcuts, and the drag button, modifiers, speed, and zoom speed. Tilt is an off-canvas sensor badge with a **Steer** or **Pointer** mode: Steer holds left/right keys past a dead zone (defaults ← / →); Pointer moves the Mac cursor. Tap the badge to recenter. Rebuild both Mac and iPhone apps before pairing because the controller schema and pairing protocol changed.

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
