import AppKit
import Security
import Carbon

struct AppSettings: Codable {
    var keyCode: UInt32 = UInt32(kVK_F2)
    var modifiers: UInt32 = 0
    var keyLabel = "F2"
    var target = "zh"
    var shortcut: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let value = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") } }
}

enum CredentialStore {
    private static let service = "local.gaoqi.screen-translator.baidu"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "translation-api"]
    }
    static func load() throws -> BaiduCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TranslatorError.message("无法读取系统钥匙串（\(status)）。请在设置中重新保存密钥。")
        }
        return try JSONDecoder().decode(BaiduCredentials.self, from: data)
    }
    static func save(_ credentials: BaiduCredentials) throws {
        if !credentials.isConfigured {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TranslatorError.message("无法清除钥匙串凭据（\(status)）。")
            }
            return
        }
        let value = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw TranslatorError.message("无法保存到系统钥匙串（\(added)）。") }
        } else if status != errSecSuccess { throw TranslatorError.message("无法更新系统钥匙串（\(status)）。") }
    }
}

final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var active: AppSettings?
    var action: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ settings: AppSettings) throws {
        if hotKey != nil, let active, active.keyCode == settings.keyCode && active.modifiers == settings.modifiers { return }
        var next: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5354524E, id: 1)
        let status = RegisterEventHotKey(settings.keyCode, settings.modifiers, id, GetApplicationEventTarget(), 0, &next)
        guard status == noErr else { throw TranslatorError.message("快捷键 \(settings.shortcut) 已被其他应用占用，请换一个组合键。") }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = next; active = settings
    }
    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class ShortcutRecorder: NSTextField {
    var shortcutSettings = AppSettings() {
        didSet { stringValue = shortcutSettings.shortcut; setAccessibilityValue(shortcutSettings.shortcut) }
    }
    var onRecordingChange: ((Bool) -> Void)?
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !recording { recording = true; onRecordingChange?(true) }
        stringValue = "按下快捷键…"
        backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let label = ShortcutKey.label(keyCode: event.keyCode, flags: flags,
                                             characters: event.charactersIgnoringModifiers) else { NSSound.beep(); return }
        shortcutSettings.keyCode = UInt32(event.keyCode)
        shortcutSettings.keyLabel = label
        shortcutSettings.modifiers = ShortcutKey.carbonModifiers(flags)
        finish()
    }
    private func finish() {
        endRecording()
        window?.makeFirstResponder(nil)
    }
    private func endRecording() {
        stringValue = shortcutSettings.shortcut
        backgroundColor = .textBackgroundColor
        if recording { recording = false; onRecordingChange?(false) }
    }
    override func resignFirstResponder() -> Bool { endRecording(); return super.resignFirstResponder() }
}

final class SettingsController: NSWindowController {
    private let appID = NSTextField()
    private let secret = NSSecureTextField()
    private let recorder = ShortcutRecorder()
    private let language = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let languages = [("简体中文", "zh"), ("繁體中文", "cht"), ("English", "en"), ("日本語", "jp"), ("한국어", "kor")]
    var onSave: ((AppSettings, BaiduCredentials) throws -> Void)?
    var onShortcutRecording: ((Bool) -> Void)?
    var onCapture: (() -> Void)?
    var onOpenPermissions: (() -> Void)?

    init(settings: AppSettings, credentials: BaiduCredentials?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 442),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "截屏翻译 · 主界面"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSView(); window.contentView = content
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                                     stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        let title = NSTextField(labelWithString: "框选一下，译文留在原处。")
        title.font = .systemFont(ofSize: 22, weight: .semibold); stack.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "点击“截图”或按快捷键框选，译图原位显示，Esc 关闭。")
        subtitle.textColor = .secondaryLabelColor; stack.addArrangedSubview(subtitle)
        let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
        appID.placeholderString = "百度翻译开放平台 APP ID"
        appID.stringValue = credentials?.appID ?? ""; appID.identifier = NSUserInterfaceItemIdentifier("appID")
        secret.placeholderString = "对应的密钥"; secret.stringValue = credentials?.secret ?? ""
        secret.identifier = NSUserInterfaceItemIdentifier("secret")
        for field in [appID, secret] {
            field.isEditable = true; field.isSelectable = true
            field.font = .systemFont(ofSize: 13); field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        recorder.isEditable = false; recorder.isSelectable = false; recorder.isBezeled = true
        recorder.drawsBackground = true; recorder.alignment = .center; recorder.font = .systemFont(ofSize: 15, weight: .medium)
        recorder.shortcutSettings = settings; recorder.toolTip = "点击录入：F1–F20 可单独设置；字母需包含 ⌃、⌥ 或 ⌘。"
        recorder.setAccessibilityElement(true); recorder.setAccessibilityRole(.button); recorder.setAccessibilityLabel("截图快捷键")
        recorder.onRecordingChange = { [weak self] active in self?.onShortcutRecording?(active) }
        language.addItems(withTitles: languages.map { $0.0 })
        language.selectItem(at: languages.firstIndex(where: { $0.1 == settings.target }) ?? 0)
        let capture = NSButton(title: "截图", target: self, action: #selector(captureClicked))
        capture.bezelStyle = .rounded; capture.toolTip = "保存当前配置并隐藏主界面，框选要翻译的区域。"
        capture.widthAnchor.constraint(equalToConstant: 64).isActive = true
        recorder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let captureControls = NSStackView(views: [recorder, capture]); captureControls.spacing = 10
        captureControls.orientation = .horizontal
        stack.addArrangedSubview(row("APP ID", appID)); stack.addArrangedSubview(row("密钥", secret))
        stack.addArrangedSubview(row("截图快捷键", captureControls)); stack.addArrangedSubview(row("翻译为", language))
        let note = NSTextField(wrappingLabelWithString: "需在百度翻译开放平台开通“图片翻译”服务。仅上传框选区域，凭据保存在这台 Mac 的系统钥匙串中。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 10
        let portal = NSButton(title: "百度控制台 ↗", target: self, action: #selector(openPortal))
        portal.bezelStyle = .inline
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        let permissions = NSButton(title: "屏幕录制权限…", target: self, action: #selector(openPermissions))
        permissions.bezelStyle = .inline
        actions.addArrangedSubview(portal); actions.addArrangedSubview(permissions); actions.addArrangedSubview(save); stack.addArrangedSubview(actions)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        stack.addArrangedSubview(status)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func row(_ label: String, _ field: NSView) -> NSView {
        let title = NSTextField(labelWithString: label); title.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let row = NSStackView(views: [title, field]); row.orientation = .horizontal; row.spacing = 12
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return row
    }
    func present() { NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    @objc private func openPortal() { NSWorkspace.shared.open(URL(string: "https://api.fanyi.baidu.com/manage/developer")!) }
    @objc private func openPermissions() { onOpenPermissions?() }

    private func persist() throws -> (AppSettings, BaiduCredentials) {
        window?.makeFirstResponder(nil)
        var value = recorder.shortcutSettings; value.target = languages[language.indexOfSelectedItem].1
        let credentials = BaiduCredentials(appID: appID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                           secret: secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard credentials.appID.isEmpty == credentials.secret.isEmpty else {
            throw TranslatorError.message("请同时填写 APP ID 和密钥，或同时清空。")
        }
        try onSave?(value, credentials)
        return (value, credentials)
    }
    @objc private func saveSettings() {
        do {
            let (value, credentials) = try persist()
            status.stringValue = credentials.isConfigured ? "已保存。按 \(value.shortcut) 开始截图翻译。" : "快捷键已保存；填写凭据后即可翻译。"
            status.textColor = .systemGreen
            window?.makeFirstResponder(nil)
        } catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
    @objc private func captureClicked() { requestCapture() }
    func requestCapture() {
        do {
            // Validate before saving so an incomplete draft never overwrites existing credentials.
            guard !appID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslatorError.message("请先填写 APP ID 和密钥，再点击截图。")
            }
            _ = try persist()
            onCapture?()
        } catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
}
