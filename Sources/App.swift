import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = AppSettings.load()
    private var credentials: BaiduCredentials?
    private var statusItem: NSStatusItem!
    private let hotkey = GlobalHotKey()
    private var settingsWindow: SettingsController?
    private var selection: SelectionCoordinator?
    private var overlay: TranslationOverlay?
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private let client = TranslationClient()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { credentials = try CredentialStore.load() }
        catch { showError(error.localizedDescription) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "ScreenTranslatorStatusItem"
        statusItem.isVisible = true
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.toolTip = "截屏翻译 · 主界面与退出"
        statusItem.button?.setAccessibilityLabel("截屏翻译菜单")
        hotkey.action = { [weak self] in self?.requestCapture() }
        do { try hotkey.register(settings) } catch { showError(error.localizedDescription) }
        refreshMenu()
        let showOnce = UserDefaults.standard.bool(forKey: "showMainWindowOnNextLaunch")
        if showOnce { UserDefaults.standard.removeObject(forKey: "showMainWindowOnNextLaunch") }
        if credentials?.isConfigured != true || showOnce { showSettings() }
        if ProcessInfo.processInfo.arguments.contains("--preview-overlay") { previewOverlay() }
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let config = NSMenuItem(title: "主界面", action: #selector(settingsClicked), keyEquivalent: "")
        config.target = self; menu.addItem(config)
        let quit = NSMenuItem(title: "退出", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); statusItem.menu = menu
        let main = NSMenu(), applicationMenu = NSMenu()
        let applicationItem = NSMenuItem(); main.addItem(applicationItem); applicationItem.submenu = applicationMenu
        applicationMenu.addItem(config.copy() as! NSMenuItem); applicationMenu.addItem(.separator())
        applicationMenu.addItem(quit.copy() as! NSMenuItem)
        // Standard responder-chain actions are required for Cmd-V in AppKit field editors.
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu; main.addItem(editItem)
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                       ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        NSApp.mainMenu = main
    }

    private static func menuBarIcon() -> NSImage {
        // A template monogram stays legible in both light and dark menu bars.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            NSColor.black.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            border.lineWidth = 1.15; border.stroke()
            let text = "译" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "截屏翻译菜单"
        return image
    }

    @objc private func settingsClicked() { showSettings() }
    @objc private func quitClicked() { closeOperation(); NSApp.terminate(nil) }
    @objc private func permissionClicked() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsController(settings: settings, credentials: credentials)
            controller.onCapture = { [weak self] in self?.startCapture() }
            controller.onOpenPermissions = { [weak self] in self?.permissionClicked() }
            controller.onShortcutRecording = { [weak self] recording in
                guard let self else { return }
                if recording { self.hotkey.suspend() }
                else { try? self.hotkey.register(self.settings) }
            }
            controller.onSave = { [weak self] value, credentials in
                guard let self else { return }
                let previous = self.settings
                try self.hotkey.register(value)
                do { try CredentialStore.save(credentials) }
                catch { try? self.hotkey.register(previous); throw error }
                self.settings = value; self.credentials = credentials; value.save(); self.refreshMenu()
            }
            settingsWindow = controller
        }
        settingsWindow?.present()
    }

    private func requestCapture() {
        if let controller = settingsWindow, controller.window?.isVisible == true {
            controller.requestCapture()
        } else { startCapture() }
    }

    private func startCapture() {
        closeOperation()
        guard let credentials, credentials.isConfigured else { showSettings(); return }
        settingsWindow?.window?.orderOut(nil)
        // ScreenCaptureKit performs its own authorization. CoreGraphics preflight
        // can be stale after approval/rebuild and must not prevent a real attempt.
        let selector = SelectionCoordinator(); selection = selector
        let id = operationID
        selector.onCancel = { [weak self] in self?.closeOperation() }
        selector.onSelection = { [weak self] image, frame in
            guard let self, self.operationID == id else { return }
            self.selection = nil
            self.translate(image, frame: frame, credentials: credentials, operation: id)
        }
        task = Task { [weak self] in
            do {
                // Wait for the main window's orderOut to reach the compositor.
                try await Task.sleep(nanoseconds: 180_000_000)
                try Task.checkCancellation()
                try await selector.begin()
            }
            catch is CancellationError { }
            catch {
                guard let self, self.operationID == id else { return }
                self.closeOperation()
                if CaptureFailure.isPermissionDenied(error) { self.showCapturePermissionHelp() }
                else { self.showError("截图未完成（\(CaptureFailure.diagnostic(error))）。请重新框选；这不一定是权限问题。") }
            }
        }
    }

    private func translate(_ image: CGImage, frame: CGRect, credentials: BaiduCredentials, operation id: UUID) {
        let result = TranslationOverlay(image: image, rect: frame)
        result.onClose = { [weak self] in self?.closeOperation() }
        overlay = result; result.show()
        let target = settings.target, client = self.client
        task = Task { [weak self] in
            let start = Date()
            do {
                // Encoding large images off the UI thread keeps Escape/cancel responsive.
                let processing = Task.detached(priority: .userInitiated) { try ImagePipeline.prepare(image) }
                let prepared = try await withTaskCancellationHandler(operation: { try await processing.value }, onCancel: { processing.cancel() })
                try Task.checkCancellation()
                let translated = try await client.translate(image: prepared, credentials: credentials, target: target)
                try Task.checkCancellation()
                guard let self, self.operationID == id else { return }
                self.overlay?.complete(translated, elapsed: Date().timeIntervalSince(start)); self.task = nil
            } catch is CancellationError { }
            catch {
                guard let self, self.operationID == id else { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                self.closeOperation()
                if error is URLError { self.showError("请求百度失败，请检查网络后重试。截图不会自动重发。") }
                else { self.showError(error.localizedDescription) }
            }
        }
    }

    private func closeOperation() {
        operationID = UUID(); task?.cancel(); task = nil
        selection?.dismiss(); selection = nil
        overlay?.dismiss(); overlay = nil
    }
    private func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "截屏翻译"; alert.informativeText = text
        alert.addButton(withTitle: "好"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    private func showCapturePermissionHelp() {
        let alert = NSAlert(); alert.messageText = "当前版本尚未取得截图授权"
        alert.informativeText = "请在“屏幕与系统录音”中关闭再开启“截屏翻译”，然后从菜单栏退出并重新打开应用。系统开关可能仍对应旧版本的签名。请使用 ~/Applications 中安装的这一份应用。"
        alert.addButton(withTitle: "打开系统设置"); alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { permissionClicked() }
    }
    func applicationWillTerminate(_ notification: Notification) { closeOperation() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    // Explicit local preview: no capture, no network, no credentials, no translation claims.
    private func previewOverlay() {
        let rect = CGRect(x: 300, y: 300, width: 540, height: 180)
        let demo = NSImage(size: rect.size, flipped: false) { bounds in
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            ("本地界面预览（未调用翻译）" as NSString).draw(at: CGPoint(x: 25, y: 85), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.labelColor])
            return true
        }
        var bounds = CGRect(origin: .zero, size: rect.size)
        if let image = demo.cgImage(forProposedRect: &bounds, context: nil, hints: nil) {
            let result = TranslationOverlay(image: image, rect: rect)
            result.onClose = { [weak self] in self?.closeOperation() }
            overlay = result; result.show(); result.complete(image, elapsed: 0)
        }
    }
}
