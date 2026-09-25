// Prompt Check Live: grades what you are typing or dictating into the Claude app's message box,
// in a small overlay pinned just above the box. Reads the box through the macOS Accessibility API
// and asks the local Prompt Check server (server.mjs), which holds the TypeSafe key.
import AppKit
import ApplicationServices

let claudeID = "com.anthropic.claudefordesktop"
let port = ProcessInfo.processInfo.environment["PORT"] ?? "4747"
let checkURL = URL(string: "http://127.0.0.1:\(port)/api/check")!
let effortNames = ["low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra high", "max": "Max"]
let checkNames = ["goal": "goal", "context": "context", "format": "format", "constraints": "limits"]
// What the Claude app's own effort button calls each level ("Effort: Extra"), lowest first.
let effortOrder = ["low", "medium", "high", "xhigh", "max"]
let appEffortNames = ["low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra", "max": "Max"]

func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
}

// The Code tab's message box is an AXTextArea described as "Prompt". Other text areas in the
// app (the browser pane, the URL bar) are skipped so the overlay only follows the message box.
func isMessageBox(_ e: AXUIElement) -> Bool {
  guard attr(e, "AXRole") as? String == "AXTextArea" else { return false }
  let desc = (attr(e, "AXDescription") as? String ?? "").lowercased()
  let placeholder = (attr(e, "AXPlaceholderValue") as? String ?? "").lowercased()
  return desc.contains("prompt") || desc.contains("message") || placeholder.contains("reply")
    || placeholder.contains("help you")
}

// Claude's effort control is an AXPopUpButton titled "Effort: <level>". Pressing it opens a popover
// with an AXSlider "Effort"; AXIncrement/AXDecrement move it one level and the button's title
// follows. Escape closes the popover and focus returns to the message box. Tested 2026-09-25.
func effortLevel(of button: AXUIElement) -> String? {
  for key in ["AXTitle", "AXDescription", "AXValue"] {
    guard let s = attr(button, key) as? String, s.hasPrefix("Effort: ") else { continue }
    let name = s.dropFirst("Effort: ".count).trimmingCharacters(in: .whitespaces)
    return appEffortNames.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }?.key
  }
  return nil
}

func findFirst(_ e: AXUIElement, _ depth: Int = 0, _ ok: (AXUIElement) -> Bool) -> AXUIElement? {
  if ok(e) { return e }
  if depth > 40 { return nil }
  for kid in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
    if let hit = findFirst(kid, depth + 1, ok) { return hit }
  }
  return nil
}

func isEffortButton(_ e: AXUIElement) -> Bool {
  attr(e, "AXRole") as? String == "AXPopUpButton" && effortLevel(of: e) != nil
}

// Search outward from the message box, so with two sessions side by side the one it belongs to moves.
func effortButton(near box: AXUIElement) -> AXUIElement? {
  var node = box
  for _ in 0..<12 {
    guard let up = attr(node, "AXParent") else { return nil }
    node = up as! AXUIElement
    if let hit = findFirst(node, 0, isEffortButton) { return hit }
  }
  return nil
}

// Lowering is always done for you. Raising is done only as far as High; Extra and Max stay a
// suggestion, since they cost the most and the grade is a guess about the task, not the result.
func autoTarget(suggested: String, current: String) -> String? {
  guard let s = effortOrder.firstIndex(of: suggested), let c = effortOrder.firstIndex(of: current) else { return nil }
  if s < c { return suggested }
  let high = effortOrder.firstIndex(of: "high")!
  if s > c && c < high { return effortOrder[min(s, high)] }
  return nil
}

// Opens the popover, steps the slider to `target`, closes it, and puts focus back in the box.
// Returns the level the button shows afterwards. Blocks the main thread for well under a second.
func setEffort(_ target: String, button: AXUIElement, box: AXUIElement, pid: pid_t) -> String? {
  guard var now = effortLevel(of: button), let to = effortOrder.firstIndex(of: target) else { return nil }
  if now == target { return now }
  AXUIElementPerformAction(button, "AXPress" as CFString)
  let root = attr(button, "AXWindow").map { $0 as! AXUIElement } ?? button
  var slider: AXUIElement?
  for _ in 0..<10 where slider == nil {
    usleep(60_000)
    slider = findFirst(root, 0) { attr($0, "AXRole") as? String == "AXSlider"
      && (attr($0, "AXDescription") as? String ?? attr($0, "AXTitle") as? String ?? "").hasPrefix("Effort") }
  }
  // Escape is sent only when the popover is known to be open: in the message box itself it would
  // stop a reply that's still running.
  guard let slider else { return effortLevel(of: button) }
  do {
    for _ in 0..<effortOrder.count {
      guard let from = effortOrder.firstIndex(of: now), from != to else { break }
      AXUIElementPerformAction(slider, (from < to ? "AXIncrement" : "AXDecrement") as CFString)
      usleep(120_000)
      guard let next = effortLevel(of: button), next != now else { break } // didn't move: stop
      now = next
    }
  }
  let src = CGEventSource(stateID: .hidSystemState)
  for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.postToPid(pid) }
  usleep(150_000)
  AXUIElementSetAttributeValue(box, "AXFocused" as CFString, kCFBooleanTrue)
  return effortLevel(of: button)
}

final class Overlay {
  let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 50),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  let title = NSTextField(labelWithString: "")
  let detail = NSTextField(labelWithString: "")

  init() {
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true // never steals a click from Claude
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let box = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
    box.wantsLayer = true
    box.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    box.layer?.borderColor = NSColor.separatorColor.cgColor
    box.layer?.borderWidth = 1
    box.layer?.cornerRadius = 6
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    for (label, y) in [(title, 26.0), (detail, 8.0)] {
      label.frame = NSRect(x: 12, y: y, width: 316, height: 17)
      label.lineBreakMode = .byTruncatingTail
      box.addSubview(label)
    }
    panel.contentView = box
  }

  // AX frames are top-left origin on the primary screen; AppKit is bottom-left.
  func place(above box: AXUIElement) {
    guard let posRef = attr(box, "AXPosition"), let sizeRef = attr(box, "AXSize") else { return }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    let screenH = NSScreen.screens.first?.frame.height ?? 0
    let w = panel.frame.width
    panel.setFrameOrigin(NSPoint(x: pos.x + size.width - w, y: screenH - pos.y + 6))
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  func hide() { if panel.isVisible { panel.orderOut(nil) } }

  func show(verdict: String, key: String, effort: String, dim: Bool, detailText: String) {
    let color: NSColor = key == "ready" ? .systemGreen : key == "missing" ? .systemRed : .systemOrange
    let s = NSMutableAttributedString(string: verdict, attributes: [.foregroundColor: color])
    s.append(NSAttributedString(string: "  ·  \(effort)",
                                attributes: [.foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor]))
    title.attributedStringValue = s
    detail.stringValue = detailText
  }

  func message(_ head: String, _ sub: String) {
    title.attributedStringValue = NSAttributedString(string: head, attributes: [.foregroundColor: NSColor.labelColor])
    detail.stringValue = sub
  }
}

final class Watcher: NSObject {
  let overlay = Overlay()
  var status: NSStatusItem!
  var paused = false
  var appPid: pid_t = 0
  var appAX: AXUIElement?
  var lastText = ""
  var changedAt = Date.distantPast
  var pending = false
  var seq = 0
  var task: URLSessionDataTask?
  var autoEffort = UserDefaults.standard.object(forKey: "autoEffort") as? Bool ?? true
  var suggestion: (text: String, level: String, shaky: Bool)? // latest grade, waiting for a pause
  var weSet: String?        // the level this overlay set for the message being written
  var userOverrode = false  // you moved the slider yourself after that: hands off until you send
  var lastResult: [String: Any]?

  func start() {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.title = "Jev"
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "p"))
    let auto = NSMenuItem(title: "Set effort automatically", action: #selector(toggleAuto(_:)), keyEquivalent: "e")
    auto.target = self
    auto.state = autoEffort ? .on : .off
    menu.addItem(auto)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Prompt Check Live", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    menu.items[0].target = self
    status.menu = menu
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
      status.button?.title = "Jev: needs Accessibility"
    }
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
  }

  @objc func togglePause(_ item: NSMenuItem) {
    paused.toggle()
    item.title = paused ? "Resume" : "Pause"
    status.button?.title = paused ? "Jev (paused)" : "Jev"
    if paused { overlay.hide(); task?.cancel() }
  }

  @objc func toggleAuto(_ item: NSMenuItem) {
    autoEffort.toggle()
    UserDefaults.standard.set(autoEffort, forKey: "autoEffort")
    item.state = autoEffort ? .on : .off
    if let d = lastResult { render(d) }
  }

  func tick() {
    guard !paused, AXIsProcessTrusted(),
          let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == claudeID
    else { return overlay.hide() }
    if front.processIdentifier != appPid {
      appPid = front.processIdentifier
      appAX = AXUIElementCreateApplication(appPid)
      // Electron builds its accessibility tree only when a client asks for it.
      AXUIElementSetAttributeValue(appAX!, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    guard let app = appAX, let focusedRef = attr(app, "AXFocusedUIElement") else { return overlay.hide() }
    let focused = focusedRef as! AXUIElement
    guard isMessageBox(focused) else { return overlay.hide() }
    let text = (attr(focused, "AXValue") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { // sent or cleared: the next message starts fresh
      lastText = ""; pending = false; task?.cancel()
      suggestion = nil; weSet = nil; userOverrode = false; lastResult = nil
      return overlay.hide()
    }
    if text != lastText {
      if lastText.isEmpty { overlay.message("Checking…", "") }
      lastText = text; changedAt = Date(); pending = true
    }
    overlay.place(above: focused)
    if pending && Date().timeIntervalSince(changedAt) >= 0.25 { // debounce, like the web page
      pending = false
      check(text)
    }
    // Wait for a one-second pause, so the popover never opens while you're mid-sentence.
    if autoEffort, !userOverrode, !pending, let s = suggestion, s.text == text, !s.shaky,
       Date().timeIntervalSince(changedAt) >= 1.0 {
      suggestion = nil
      applyEffort(s.level, box: focused)
    }
  }

  func applyEffort(_ level: String, box: AXUIElement) {
    guard let button = effortButton(near: box), let current = effortLevel(of: button) else {
      return NSLog("effort: no effort button next to this message box")
    }
    if let weSet, current != weSet { userOverrode = true; return NSLog("effort: you changed it to \(current); leaving it") }
    guard let target = autoTarget(suggested: level, current: current) else {
      return NSLog("effort: suggested \(level), at \(current); no change by the rules")
    }
    weSet = setEffort(target, button: button, box: box, pid: appPid)
    NSLog("effort: suggested \(level), was \(current), asked \(target), now \(weSet ?? "?")")
    if let d = lastResult { render(d) }
  }

  func check(_ text: String) {
    task?.cancel() // a newer keystroke wins
    seq += 1
    let mine = seq
    var req = URLRequest(url: checkURL)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": text])
    req.timeoutInterval = 5
    task = URLSession.shared.dataTask(with: req) { data, _, err in
      DispatchQueue.main.async { [weak self] in
        guard let self, mine == self.seq, !self.paused else { return }
        if let err = err as? URLError, err.code == .cancelled { return }
        guard let data, let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          return self.overlay.message("Prompt Check server isn't running", "Double-click Prompt Check Live.command")
        }
        if let e = d["error"] as? String { return self.overlay.message("Can't check", e) }
        self.lastResult = d
        if let e = d["effort"] as? [String: Any], let level = e["level"] as? String {
          self.suggestion = (text, level, e["shaky"] as? Bool ?? false)
          if e["shaky"] as? Bool ?? false { NSLog("effort: \(level) is only a guess; not setting it") }
        }
        self.render(d)
      }
    }
    task?.resume()
  }

  func render(_ d: [String: Any]) {
    guard let v = d["verdict"] as? [String: Any], let e = d["effort"] as? [String: Any] else { return }
    // New tasks list what's missing; replies and questions show the verdict's note instead.
    let missing = (d["missing"] as? [String] ?? []).compactMap { checkNames[$0] }
    var parts: [String] = []
    if !missing.isEmpty { parts.append("Missing: " + missing.joined(separator: ", ")) }
    else if let note = v["note"] as? String { parts.append(note.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    if d["padded"] as? Bool ?? false { parts.append("wordy") }
    if let hint = d["modelHint"] as? String { parts.append(hint) }
    parts.append("\(d["ms"] as? Int ?? 0) ms")
    let level = e["level"] as? String ?? "", shaky = e["shaky"] as? Bool ?? false
    let name = effortNames[level] ?? "?"
    var effortText = "Run at \(name)\(shaky ? " (guess)" : "")"
    if autoEffort, let set = weSet, let setName = effortNames[set] {
      effortText = set == level ? "Effort set to \(setName)" : "Set to \(setName) · \(name) suggested"
    }
    overlay.show(verdict: v["label"] as? String ?? "", key: v["key"] as? String ?? "",
                 effort: effortText, dim: shaky && weSet == nil, detailText: parts.joined(separator: " · "))
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let watcher = Watcher()
watcher.start()
app.run()
