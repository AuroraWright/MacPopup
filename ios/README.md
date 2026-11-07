# MacPopup for iPhone (Experiment)

An experimental iPhone app (iOS 18 or later), separate from MacPopup, the Mac app in the rest of this repository. It
shares MacPopup's OCR engines (`Sources/OCREngines`, a package target both apps use) but none of its other code, and
isn't part of MacPopup's build.

It reads the text in a picture and opens it in **Safari**, as the picture with invisible text over it, for a Safari
dictionary extension such as Yomitan to look up. Readings keep opening in Safari after the app is closed.

Build it by opening `ios/MacPopup.xcodeproj` in Xcode, choosing your own team under *Signing & Capabilities* for each
target (MacPopup, Controls, Share and Broadcast), and running it on your iPhone. Node.js is needed, as for the Mac
app. The app has Live Text, meikiocr and PP-OCRv6 Manga, and Screen AI and OneOCR once their models are loaded: put
the same .zip files the Mac app loads (see [OCR Engines](../README.md#ocr-engines)) in Files, then load them in the
app's Settings. **Google Lens** and **Bing** read online, with the requests the Mac app's cloud recognition makes: the
picture is sent to Google or Microsoft. Their requests go through libcurl-impersonate, as on the Mac (Bing refuses
others on some networks); the build downloads its iOS release into `build/cache` and puts it in the app
(`ios/embed-curl-impersonate.sh`).

Pictures can come from Photos, Files, the clipboard, or the latest screenshots, which the app lists once it's allowed
full access to Photos. They can also be shared to **MacPopup** from other apps' share sheets, including an image
long-pressed in Safari. With *Crop before reading* on (Settings), pictures chosen in the app open in a crop view first.
Swipe a reading left to delete it. To read what's on the screen without opening the app:

- **Back Tap** (*Settings → Accessibility → Touch → Back Tap*): make a Shortcut with **Take Screenshot** followed by
  MacPopup's **Read Image**, and choose it for Double or Triple Tap. The screenshot is read with the app in the
  background, and the reading opens in Safari.
- **Action button** (iPhone 15 Pro and later, *Settings → Action Button*): choose the same Shortcut, or choose
  *Controls* and MacPopup's **Read Latest Screenshot** to read the screenshot taken last.
- **Control Center**: add MacPopup's **Read Latest Screenshot** control, take a screenshot, then tap the control.
- **Siri**: "Read my latest screenshot with MacPopup".
- **Visual Intelligence** (iOS 26 with Apple Intelligence): from the camera (Action button, Control Center or Camera
  Control) or a screenshot's Visual Intelligence button, pick MacPopup's *Read with MacPopup* result. The picture is
  read when you open it, and the reading opens in Safari.

**Continuous Reading** reads the screen as it changes, e.g. a game's dialogue, while you play. Tap *Start Reading the
Screen* (a screen broadcast, also in Control Center), switch to the game, then come back and *Add Area…* around the
dialogue on a screen it read, so that only that part is watched and read. Each new line goes to the live page in
Safari (*Open the Live Page*), newest first, with the earlier ones below; switch to it to look words up, and back to the
game. Reading pauses while the live page is in front. *Show the Latest Text* adds a Picture in Picture window over the
game with the new lines. Stopping the broadcast stops reading.

- The app keeps running in the background with a silent audio session, and reads on the CPU, since iOS doesn't let
  background apps use the GPU: about half a second per area on an iPhone 15 Pro Max. Screen AI needs the GPU, so
  continuous reading uses meikiocr instead of it, as it does instead of Google Lens and Bing (a request for each change
  of the screen).
- It uses more battery. The *Reading* settings set how often the screen is checked and how much an area must change.
- Protected video (DRM) comes out black in a broadcast.
