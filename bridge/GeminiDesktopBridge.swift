import AppKit
import ApplicationServices

private let geminiID = "com.google.GeminiMacOS"

struct Request: Decodable {
    let action: String
    let mode: String?
    let model: String?
    let directory: String?
    let message: String?
    let marker: String?
    let windowTitle: String?
    let deadline: TimeInterval
}

struct BridgeError: Error {
    let code: String
    let detail: String

    init(_ code: String, _ detail: String) {
        self.code = code
        self.detail = detail
    }
}

func attr(_ item: AXUIElement, _ key: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success else { return nil }
    return value
}

func label(_ item: AXUIElement, _ key: String = "AXTitle") -> String {
    attr(item, key) as? String ?? ""
}

func nodes(_ item: AXUIElement, skipSidebar: Bool = true, depth: Int = 0) -> [AXUIElement] {
    guard depth < 28 else { return [] }
    if skipSidebar && label(item, "AXRole") == "AXOutline" { return [] }
    let children = attr(item, "AXChildren") as? [AXUIElement] ?? []
    return [item] + children.flatMap { nodes($0, skipSidebar: skipSidebar, depth: depth + 1) }
}

func labels(_ item: AXUIElement) -> [String] {
    ["AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue"].map { label(item, $0) }
}

func button(_ items: [AXUIElement], _ names: [String]) -> AXUIElement? {
    items.first { item in
        ["AXButton", "AXMenuItem", "AXRadioButton"].contains(label(item, "AXRole")) &&
        !(Set(labels(item) + [label(item, "AXIdentifier")]).isDisjoint(with: names))
    }
}

func sleepBriefly() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
}

final class Gemini {
    private let request: Request
    private let armedURL: URL
    private var app: NSRunningApplication!
    private var root: AXUIElement!

    init(_ request: Request, armedURL: URL) throws {
        self.request = request
        self.armedURL = armedURL
        if NSRunningApplication.runningApplications(withBundleIdentifier: geminiID).isEmpty {
            try openGemini(inBackground: request.action == "query")
        }
        app = try waitFor("launch_failed", "Gemini Desktop did not start.", seconds: 12) {
            NSRunningApplication.runningApplications(withBundleIdentifier: geminiID).first
        }
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.3)
        if request.action != "query" {
            app.activate()
            _ = try waitFor("gemini_not_frontmost", "Gemini could not become the active app.", seconds: 4) {
                self.app.isActive ? true : nil
            } as Bool
        }
        do {
            _ = try waitFor("window_unavailable", "Gemini has no accessible window. Unlock the Mac and check Gemini.", seconds: 12) {
                self.window()
            }
        } catch {
            // Launch Services can return an already-running app with all windows closed.
            try openGemini(inBackground: false)
            _ = try waitFor("window_unavailable", "Gemini has no accessible window. Unlock the Mac and check Gemini.", seconds: 5) { self.window() }
        }
    }

    private func openGemini(inBackground: Bool) throws {
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = (inBackground ? ["-g"] : []) + ["-b", geminiID]
        try launch.run()
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else {
            throw BridgeError("launch_failed", "Launch Services could not open Gemini Desktop.")
        }
    }

    private func waitFor<T>(_ code: String, _ detail: String, seconds: TimeInterval, _ probe: () -> T?) throws -> T {
        let end = min(request.deadline, Date().timeIntervalSince1970 + seconds)
        repeat {
            if let value = probe() { return value }
            sleepBriefly()
        } while Date().timeIntervalSince1970 < end
        throw BridgeError(code, detail)
    }

    private func window() -> AXUIElement? {
        if let focused = attr(root, "AXFocusedWindow") { return (focused as! AXUIElement) }
        return (attr(root, "AXWindows") as? [AXUIElement])?.first
    }

    private func mainWindow() -> AXUIElement? {
        let windows = attr(root, "AXWindows") as? [AXUIElement] ?? []
        return windows.first { label($0).hasPrefix("Gemini") && label($0, "AXIdentifier") != "open-panel" }
    }

    private func items() -> [AXUIElement] {
        window().map { nodes($0) } ?? []
    }

    private func matchingButton(_ names: [String], seconds: TimeInterval = 4) throws -> AXUIElement {
        try waitFor("control_missing", "Gemini did not expose the expected control (\(names[0])). Check login, modal dialogs, and app language.", seconds: seconds) {
            button(self.items(), names)
        }
    }

    private func press(_ item: AXUIElement, allowTimeout: Bool = false) throws {
        guard Date().timeIntervalSince1970 < request.deadline else {
            throw BridgeError("ui_deadline", "The desktop operation ran out of time.")
        }
        let result = AXUIElementPerformAction(item, "AXPress" as CFString)
        if result != .success && !(allowTimeout && result == .cannotComplete) {
            throw BridgeError("ax_press_failed", "Gemini returned AX error \(result.rawValue).")
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        guard Date().timeIntervalSince1970 < request.deadline, app.isActive, CGPreflightPostEventAccess() else {
            throw BridgeError("keyboard_unavailable", "Gemini must be active and the bridge must have keyboard event permission.")
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    // Retain each pasteboard type and avoid restoring over an intervening user copy.
    private func preserveClipboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { original -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private func restoreClipboard(_ items: [NSPasteboardItem], change: Int) {
        let board = NSPasteboard.general
        guard board.changeCount == change else { return }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }

    private func paste(_ text: String) throws {
        let board = NSPasteboard.general
        let saved = preserveClipboard()
        board.clearContents()
        board.setString(text, forType: .string)
        let change = board.changeCount
        defer { restoreClipboard(saved, change: change) }
        try key(9, flags: .maskCommand)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
    }

    private func checkForSheet(_ items: [AXUIElement]) throws {
        if items.contains(where: { label($0, "AXRole") == "AXSheet" }) {
            throw BridgeError("gemini_dialog", "Gemini has an open dialog. Review it in Gemini, then query the same task.")
        }
    }

    private func composer(_ items: [AXUIElement]) -> AXUIElement? {
        let names = request.mode == "chat"
            ? ["问问 Gemini", "Ask Gemini"]
            : ["分配任务", "描述任务", "Assign a task", "Describe a task"]
        return items.first {
            label($0, "AXRole") == "AXTextArea" && !Set(labels($0)).isDisjoint(with: names)
        }
    }

    private func currentFolderIsNamed(_ name: String, _ items: [AXUIElement]) -> Bool {
        button(items, [name]) != nil && button(items, ["移除", "Remove"]) != nil
    }

    private func selectFolder(_ path: String) throws {
        let name = URL(fileURLWithPath: path).lastPathComponent
        try press(matchingButton(["文件夹", "Folders", "Folder"]), allowTimeout: true)
        try press(matchingButton(["添加新文件夹…", "添加新文件夹", "Add new folder…", "Add new folder...", "Add New Folder…"]))
        _ = try waitFor("picker_missing", "Gemini did not open the directory picker.", seconds: 5) {
            self.window().flatMap {
                label($0, "AXIdentifier") == "open-panel" && button(nodes($0), ["OKButton"]) != nil ? $0 : nil
            }
        }
        try key(5, flags: [.maskCommand, .maskShift])
        let pathField = try waitFor("path_input_missing", "The open panel did not show Go to Folder.", seconds: 4) {
            self.items().first { label($0, "AXRole") == "AXSheet" }
        }
        try paste(path)
        guard nodes(pathField).contains(where: { label($0, "AXValue") == path }) else {
            throw BridgeError("path_verification_failed", "The native directory picker did not accept the exact requested path.")
        }
        try key(36)
        let choose = try waitFor("directory_not_selected", "The open panel did not navigate to the requested directory.", seconds: 5) {
            let items = self.items()
            let navigated = items.contains {
                label($0, "AXIdentifier") == "where popup" && label($0, "AXValue") == name
            }
            return navigated ? button(items, ["OKButton"]) : nil
        }
        try press(choose)
        _ = try waitFor("directory_not_attached", "Gemini did not attach the directory.", seconds: 6) {
            let items = self.items()
            if self.currentFolderIsNamed(name, items) { return true }
            let sheet = items.first { label($0, "AXRole") == "AXSheet" }
            if let sheet {
                let all = nodes(sheet)
                let confirmation = all.contains { item in
                    label(item, "AXRole") == "AXStaticText" && labels(item).contains {
                        $0.contains(name) &&
                        ($0.contains("要允许 Gemini 访问") || $0.localizedCaseInsensitiveContains("allow Gemini to access"))
                    }
                }
                if confirmation, let allow = button(all, ["允许", "Allow"]) {
                    try? self.press(allow)
                }
            }
            return nil
        } as Bool
    }

    private func prepareComposer() throws {
        try checkForSheet(items())
        guard let main = mainWindow(), window().map({ CFEqual($0, main) }) == true else {
            throw BridgeError("gemini_dialog", "Close Gemini's separate dialog and bring its main window forward.")
        }
        let initial = nodes(main, skipSidebar: false)
        let newChat = button(initial, ["newChat_button"]) ??
            button(initial.filter { label($0, "AXIdentifier").isEmpty }, ["发起新对话", "New chat", "Start a new chat"])
        guard let newChat else {
            if button(initial, ["登录", "Sign in", "Sign In", "登录 Google 账号"]) != nil {
                throw BridgeError("login_required", "Sign in to Gemini Desktop and retry with a new task ID.")
            }
            throw BridgeError("new_chat_missing", "Gemini did not expose New chat. Check whether you are signed in.")
        }
        try press(newChat)
        let modeButton = request.mode == "chat" ? "chat-input-mode-ask" : "chat-input-mode-assign"
        try press(matchingButton([modeButton]))
        _ = try waitFor("mode_missing", "Gemini did not enter the requested mode.", seconds: 5) {
            self.composer(self.items())
        }
    }

    private struct ModelOption {
        let name: String
        let available: Bool
        let selected: Bool
        let item: AXUIElement
    }

    private func modelMenu() throws -> (AXUIElement, [ModelOption]) {
        let selector = try matchingButton(["tab_stop_model_selector"])
        try press(selector)
        let popover = try waitFor("model_menu_missing", "Gemini did not expose the model picker.", seconds: 4) {
            button(self.items(), ["tab_stop_model_selector"]).flatMap {
                nodes($0).first { label($0, "AXRole") == "AXPopover" }
            }
        }

        // Current Gemini exposes model rows as plain buttons. The separate
        // thinking-level control is a button with AXValue.
        let rows = nodes(popover).filter {
            label($0, "AXRole") == "AXButton" && attr($0, "AXValue") == nil
        }
        let options = rows.compactMap { item -> ModelOption? in
            guard let name = labels(item).first(where: { !$0.isEmpty }),
                  let available = attr(item, "AXEnabled") as? Bool else { return nil }
            let selected = (attr(item, "AXSelected") as? Bool) == true
            return ModelOption(name: name, available: available, selected: selected, item: item)
        }
        guard !options.isEmpty, options.count == rows.count,
              Set(options.map(\.name)).count == options.count,
              options.filter(\.selected).count == 1 else {
            try? closeModelMenu(popover)
            throw BridgeError("model_menu_unrecognized", "Gemini's actual model rows or selected state could not be verified.")
        }
        return (popover, options)
    }

    private func closeModelMenu(_ popover: AXUIElement) throws {
        if AXUIElementPerformAction(popover, "AXCancel" as CFString) != .success { try key(53) }
        _ = try waitFor("model_menu_still_open", "Gemini did not close its model picker.", seconds: 2) {
            guard let selector = button(self.items(), ["tab_stop_model_selector"]) else { return nil as Bool? }
            return nodes(selector).contains { label($0, "AXRole") == "AXPopover" } ? nil : true
        }
    }

    private func chooseModel(_ name: String) throws {
        let (popover, options) = try modelMenu()
        guard let option = options.first(where: { $0.name == name && $0.available }) else {
            try closeModelMenu(popover)
            let available = options.filter(\.available).map(\.name).joined(separator: " / ")
            throw BridgeError("model_unavailable", "That exact model label is unavailable in this mode. Available: \(available).")
        }
        if option.selected {
            try closeModelMenu(popover)
            return
        }
        try press(option.item)
        _ = try waitFor("model_menu_still_open", "Gemini did not accept the model click.", seconds: 3) {
            guard let selector = button(self.items(), ["tab_stop_model_selector"]) else { return nil as Bool? }
            return nodes(selector).contains { label($0, "AXRole") == "AXPopover" } ? nil : true
        }
        let (check, observed) = try modelMenu()
        try closeModelMenu(check)
        guard observed.contains(where: { $0.name == name && $0.selected && $0.available }) else {
            throw BridgeError("model_not_selected", "Gemini did not mark the requested row selected.")
        }
    }

    func weeklyQuota() throws -> [String: Any] {
        let titles = ["用量限额", "Usage limits", "Usage Limits"]
        func settingsWindow() -> AXUIElement? {
            (attr(root, "AXWindows") as? [AXUIElement])?.first {
                nodes($0, skipSidebar: false).contains {
                    label($0, "AXIdentifier") == "settings_search_field"
                }
            }
        }
        let existing = settingsWindow()
        if existing == nil { try key(43, flags: .maskCommand) }
        let settings = try waitFor("quota_settings_unavailable", "Gemini's settings window did not open.", seconds: 5) {
            settingsWindow()
        }
        defer {
            if existing == nil, let close = attr(settings, "AXCloseButton") {
                try? press(close as! AXUIElement)
            }
        }
        let row = try waitFor("quota_page_unavailable", "Gemini Settings has no visible Usage limits page.", seconds: 4) {
            nodes(settings, skipSidebar: false).first {
                label($0, "AXRole") == "AXRow" && nodes($0).contains {
                    !Set(labels($0)).isDisjoint(with: titles)
                }
            }
        }
        if (attr(row, "AXSelected") as? Bool) != true {
            let selected = AXUIElementSetAttributeValue(row, "AXSelected" as CFString, kCFBooleanTrue)
            if selected != .success { try press(row) }
        }
        let weekly = #"(?i)(?:每周限额|weekly limit(?:s)?|weekly usage)\s*[:：]?\s*"#
        let used = #"(?i)(?:已使用\s*(\d{1,3})\s*%|(\d{1,3})\s*%\s*used|used\s*(\d{1,3})\s*%)"#
        let remaining = #"(?i)(?:剩余\s*(\d{1,3})\s*%|(\d{1,3})\s*%\s*(?:remaining|left))"#
        let reset = #"(?i)(?:重置时间\s*[:：]?|resets?\s*(?:at|on|:)?|reset time\s*:?)\s*(.+)"#
        func groups(_ pattern: String, _ text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        var section: String?
        _ = try? waitFor("quota_fields_unavailable", "Gemini did not expose weekly usage values.", seconds: 7) {
            var seen = Set<String>()
            let text = nodes(settings).filter {
                ["AXStaticText", "AXGroup", "AXHeading", "AXProgressIndicator"].contains(label($0, "AXRole"))
            }.flatMap(labels).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " ")
            guard let start = text.range(of: weekly, options: .regularExpression) else { return nil as Bool? }
            let rest = String(text[start.upperBound...])
            let boundary = rest.range(of: #"(?i)使用 AI 点数|高级设置|AI (?:points|credits)|advanced settings|learn more"#,
                                      options: .regularExpression)?.lowerBound ?? rest.endIndex
            let visible = String(rest[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            section = visible
            let hasPercent = !groups(used, visible).isEmpty || !groups(remaining, visible).isEmpty
            return hasPercent && !groups(reset, visible).isEmpty ? true : nil
        } as Bool
        let text = section ?? ""
        let usedPercent = groups(used, text).compactMap(Int.init).first { (0...100).contains($0) }
        let shownRemaining = groups(remaining, text).compactMap(Int.init).first { (0...100).contains($0) }
        let remainingPercent = shownRemaining ?? usedPercent.map { 100 - $0 }
        let resetText = groups(reset, text).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "status": remainingPercent != nil && resetText != nil ? "ready" : "quota_fields_unavailable",
            "remaining_percent": remainingPercent as Any? ?? NSNull(),
            "remaining_source": shownRemaining != nil ? "displayed" : (usedPercent != nil ? "100_minus_displayed_used_percent" : "unavailable"),
            "used_percent": usedPercent as Any? ?? NSNull(),
            "reset_display": resetText as Any? ?? NSNull()
        ]
    }

    func listModels() throws -> [String: Any] {
        try prepareComposer()
        let (popover, options) = try modelMenu()
        try closeModelMenu(popover)
        return [
            "status": "ready",
            "mode": request.mode ?? "task",
            "selected": options.first(where: \.selected)?.name as Any? ?? NSNull(),
            "models": options.map { ["label": $0.name, "available": $0.available, "selected": $0.selected] }
        ]
    }

    func submit() throws -> [String: Any] {
        guard let message = request.message, let marker = request.marker else {
            throw BridgeError("invalid_request", "The message and task marker are required.")
        }
        try prepareComposer()
        if let model = request.model { try chooseModel(model) }
        if let directory = request.directory {
            try selectFolder(directory)
            if let model = request.model {
                let (popover, options) = try modelMenu()
                try closeModelMenu(popover)
                guard options.contains(where: { $0.name == model && $0.selected && $0.available }) else {
                    throw BridgeError("model_not_selected", "Gemini changed the selected model after attaching the folder.")
                }
            }
        }
        let items = self.items()
        try checkForSheet(items)
        let attached = request.directory.map { currentFolderIsNamed(URL(fileURLWithPath: $0).lastPathComponent, items) } ?? true
        guard let input = composer(items), attached, button(items, ["stop_button"]) == nil else {
            throw BridgeError("composer_changed", "Gemini no longer has the expected task composer and directory.")
        }
        let prompt = "\(marker)\n\(message)"
        _ = AXUIElementSetAttributeValue(input, "AXFocused" as CFString, kCFBooleanTrue)
        let set = AXUIElementSetAttributeValue(input, "AXValue" as CFString, prompt as CFString)
        if set != .success || label(input, "AXValue") != prompt { try paste(prompt) }
        let send = try matchingButton(["send_button"])
        guard label(input, "AXValue") == prompt, app.isActive else {
            throw BridgeError("composer_changed", "Gemini's composer changed before submission.")
        }
        try Data().write(to: armedURL, options: .atomic)
        try press(send)
        do {
            return try waitFor("submission_unconfirmed", "Gemini did not expose the submitted task yet. Query this task ID.", seconds: 6) {
                self.observation(marker: marker)
            }
        } catch {
            return ["status": "submission_unknown", "detail": "Gemini received the press, but the task heading has not appeared. Query the same task ID."]
        }
    }

    private func observation(marker: String) -> [String: Any]? {
        guard let main = mainWindow() else { return nil }
        let items = nodes(main)
        let accepted = items.contains {
            label($0, "AXRole") == "AXHeading" && labels($0).contains { $0.hasPrefix(marker) }
        }
        guard accepted else { return nil }
        let toolbar = items.first { label($0, "AXRole") == "AXToolbar" }.map { nodes($0) } ?? []
        let failed = button(toolbar, ["失败", "任务失败", "Failed", "Canceled", "Cancelled", "已取消"])
        let complete = button(toolbar, ["已完成", "Completed", "Done"])
        let stop = button(items, ["stop_button"])
        let copy = button(items, ["copy-button"])
        var result: [String: Any] = ["status": "running", "window_title": label(main)]
        if failed != nil {
            result["status"] = "task_failed"
            result["detail"] = failed.map { labels($0).filter { !$0.isEmpty }.joined(separator: " ") }
        } else if stop == nil && (complete != nil || (request.mode == "chat" && copy != nil)) {
            if let copy, let reply = replyText(copy) {
                result["status"] = "completed"
                result["reply"] = reply
            } else {
                result["status"] = "result_unavailable"
                result["detail"] = "Gemini marked the task completed but no readable response was exposed. Query again."
            }
        } else {
            result["phase"] = toolbar.compactMap {
                labels($0).first { ["正在启动", "Starting", "正在运行", "Running"].contains($0) }
            }.first ?? "generating"
            if let modal = items.first(where: { label($0, "AXRole") == "AXSheet" }) {
                result["status"] = "attention_required"
                result["detail"] = nodes(modal).filter { label($0, "AXRole") == "AXStaticText" }
                    .flatMap { labels($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
        return result
    }

    private func replyText(_ copy: AXUIElement) -> String? {
        var ancestor = copy
        var axText: String?
        for _ in 0..<9 {
            guard let parent = attr(ancestor, "AXParent") else { break }
            ancestor = parent as! AXUIElement
            let fragments = nodes(ancestor).filter { label($0, "AXRole") == "AXStaticText" }.compactMap { item in
                labels(item).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            if fragments.count == 1 { return fragments[0] }
            if !fragments.isEmpty {
                axText = fragments.joined(separator: "\n")
                break
            }
            if label(ancestor, "AXRole") == "AXRow" { break }
        }
        guard app.isActive else { return axText }
        let board = NSPasteboard.general
        let original = preserveClipboard()
        let prior = board.changeCount
        guard (try? press(copy)) != nil else { return axText }
        guard let change = try? waitFor("clipboard_unavailable", "Gemini did not copy the response.", seconds: 1.3, {
            board.changeCount != prior ? board.changeCount : nil
        }) else { return axText }
        defer { restoreClipboard(original, change: change) }
        return board.string(forType: .string) ?? axText
    }

    func query() throws -> [String: Any] {
        guard let marker = request.marker else { throw BridgeError("invalid_request", "Missing task marker.") }
        if let observation = observation(marker: marker) { return observation }
        try checkForSheet(items())
        // Reopen the observed conversation only when its exact title is unique.
        if let title = request.windowTitle, title.hasPrefix("Gemini - "),
           let main = mainWindow() {
            let name = String(title.dropFirst("Gemini - ".count))
            let outline = nodes(main, skipSidebar: false).first { label($0, "AXRole") == "AXOutline" }
            let matches = outline.map { nodes($0, skipSidebar: false).filter {
                label($0, "AXRole") == "AXButton" && labels($0).contains(name)
            } } ?? []
            if !name.isEmpty && matches.count == 1 {
                try press(matches[0])
                if let result = try? waitFor("conversation_not_found", "Could not reopen the task.", seconds: 4, {
                    self.observation(marker: marker)
                }) { return result }
            }
        }
        return ["status": "conversation_not_found", "detail": "The task is not visible in Gemini. Open its original task conversation and query the same task ID."]
    }
}

func respond(_ payload: [String: Any], to path: URL) throws {
    try JSONSerialization.data(withJSONObject: payload).write(to: path, options: .atomic)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "--request" else {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    exit(0)
}
let requestURL = URL(fileURLWithPath: arguments[2])
let responseURL = requestURL.deletingLastPathComponent().appendingPathComponent("response.json")
let armedURL = requestURL.deletingLastPathComponent().appendingPathComponent("armed")
let helperLockURL = requestURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("helper.lock")
let lock = open(helperLockURL.path, O_CREAT | O_WRONLY, S_IRUSR | S_IWUSR)
defer { if lock >= 0 { close(lock) } }
do {
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw BridgeError("helper_busy", "The previous desktop operation is still exiting. Query or retry after it exits.")
    }
    let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
    guard AXIsProcessTrusted() else {
        throw BridgeError("accessibility_required", "Enable Gemini Desktop Bridge in System Settings → Privacy & Security → Accessibility.")
    }
    guard Date().timeIntervalSince1970 < request.deadline else {
        throw BridgeError("ui_deadline", "The desktop operation expired before startup.")
    }
    let result: [String: Any]
    if request.action == "health" {
        result = ["status": "ready", "keyboard_events": CGPreflightPostEventAccess()]
    } else {
        let gemini = try Gemini(request, armedURL: armedURL)
        switch request.action {
        case "submit": result = try gemini.submit()
        case "models": result = try gemini.listModels()
        case "quota": result = try gemini.weeklyQuota()
        case "query": result = try gemini.query()
        default: throw BridgeError("invalid_request", "Unknown helper action.")
        }
    }
    try respond(result, to: responseURL)
} catch {
    let error = error as? BridgeError ?? BridgeError("helper_error", String(describing: error))
    try? respond([
        "status": error.code, "detail": error.detail,
        "may_have_submitted": FileManager.default.fileExists(atPath: armedURL.path)
    ], to: responseURL)
}
