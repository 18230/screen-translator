# Screen Translator · 截屏翻译

**English** | [简体中文](README.zh-CN.md)

A lightweight native macOS menu bar app for personal use. Select a screen region with a keyboard shortcut, translate it with Baidu Image Translation, and display the translated image in its original position. Built with Swift and AppKit, with no third-party app dependencies, local OCR or language models, or self-hosted server.

The app's interface is currently in Chinese. This README is available in English and Simplified Chinese.

## Usage

1. Open `~/Applications/截屏翻译.app`. A framed “译” icon stays in the menu bar, with two items: **主界面** (Main Window) and **退出** (Quit). Use the main window to enter credentials, configure the shortcut and target language, or open screen recording permissions. Closing the main window keeps the app running in the menu bar; choose Quit to exit.
2. Enable **Image Translation** on the [Baidu Translate Open Platform](https://api.fanyi.baidu.com/product/22) and enter its **APP ID and secret key**. Credentials for the standalone OCR API or Baidu AI Cloud are not interchangeable with this API's credentials. Keep your secret key private.
3. Choose a target language and capture shortcut, then save. The default shortcut is **F2**. F1–F20 work on their own or with modifiers; letter keys require Command, Control, or Option. If F2 controls brightness on your keyboard, use **Fn/Globe + F2**. Both credential fields support Cmd-V, Cmd-A, and context-menu editing. Target language options are Simplified Chinese, Traditional Chinese, English, Japanese, and Korean; the source language is detected automatically.
4. Click **截图** (Capture) next to the shortcut field, or press the shortcut. The Capture button saves the current configuration and hides the main window before region selection. Grant screen recording access when macOS requests it. If capture still fails after approval, quit and reopen the app.
5. Drag to select a region and release to send it to Baidu. The translated image appears in the same position. Hold Space to view the original, and release to restore the translation. Press Esc or click the close button to dismiss it. You can also cancel while translation is in progress.

Only the selected region is uploaded. Captures and translated images are held in memory rather than saved to disk. Credentials are stored in macOS Keychain; shortcut and target language settings are stored in UserDefaults. The app has no analytics, automatic request retries, or login startup enabled by default. Network and API failures produce an error message.

## Build and install

Requires an **Apple Silicon Mac**, **macOS 15.2 or later**, and **Xcode Command Line Tools**.

```sh
bash scripts/build.sh
python3 scripts/install.py
bash scripts/test.sh
```

The build is staged in the hidden `.build/package` directory. The installer stops the previous app, unregisters and removes its bundle, then installs fresh files at `~/Applications/截屏翻译.app`. Preferences and Keychain credentials are retained. It creates `dist/截屏翻译.zip` and removes the staging app, leaving no second runnable app in `dist` that could be opened by mistake. Build output and the archive are excluded from Git.

### Local code signing and permissions

Builds use a stable, machine-specific local signing identity; a paid Apple developer account is not required. The app is intended for local use and is not notarized or distributed through the App Store.

The first build creates an app-specific self-signed certificate and a dedicated keychain in `~/Library/Application Support/ScreenTranslatorSigning`. It does not add a system trust root or change certificate trust settings. Private keys stay outside the source tree. Keep this directory so future builds on the same Mac reuse the same identity.

When upgrading from the temporary signing used in version 0.1.3 or earlier, screen recording permission may still refer to an old build. Turn the app's permission off and on in System Settings, then quit and reopen the app. Capture uses ScreenCaptureKit directly and checks the actual capture result instead of blocking on a potentially stale CoreGraphics permission preflight. Permission errors and other capture errors are reported separately.

If an obsolete permission record cannot be refreshed, install with:

```sh
python3 scripts/install.py --reset-screen-permission
```

This resets screen capture permission for this app only; the user must approve the new system request. Normal updates do not reset permissions or change other apps' access.

## Implementation and validation

- Global shortcuts use Carbon registration rather than monitoring all keystrokes. Accessibility permission is not required.
- Capture temporarily freezes each display for region selection. You can select within any one display; a single selection cannot span multiple displays.
- Image preparation enforces a minimum side length of 30 px, maximum side length of 4096 px, aspect ratio no greater than 3:1, and upload size below 4 MB. Narrow selections receive symmetric padding; large images are resized or compressed. Padding is removed before showing the translated image.
- Requests use the Image Translation V1 endpoint, `https://fanyi-api.baidu.com/api/trans/sdk/picture`, with `version=3` and `paste=1`. The signature is `md5(appid + md5(imageBytes) + salt + cuid + mac + secret)`, computed from the exact uploaded bytes. Baidu returns the translated image; the client does not erase text or compose translations itself.
- Tests cover independent signature verification, the image request protocol, response decoding, error handling, Retina and secondary-display coordinates, padding removal, shortcut handling, capture error classification, selection rendering, and a mocked request/response flow.
- Automated tests do not call the live Baidu service. Verifying live translation quality, latency, and account quotas requires valid credentials and an enabled Image Translation service.
- Refer to the Baidu console for current pricing and quotas.

References: [Image Translation product](https://api.fanyi.baidu.com/product/22) · [API documentation](https://api.fanyi.baidu.com/doc/26).
