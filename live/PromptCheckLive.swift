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

  func show(verdict: String, key: String, effort: String, shaky: Bool, detailText: String) {
    let color: NSColor = key == "ready" ? .systemGreen : key == "missing" ? .systemRed : .systemOrange
    let s = NSMutableAttributedString(string: verdict, attributes: [.foregroundColor: color])
    s.append(NSAttributedString(string: "  ·  Run at \(effort)\(shaky ? " (guess)" : "")",
                                attributes: [.foregroundColor: shaky ? NSColor.secondaryLabelColor : NSColor.labelColor]))
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

  func start() {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.title = "Jev"
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "p"))
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
    if text.isEmpty { lastText = ""; pending = false; task?.cancel(); return overlay.hide() }
    if text != lastText {
      if lastText.isEmpty { overlay.message("Checking…", "") }
      lastText = text; changedAt = Date(); pending = true
    }
    overlay.place(above: focused)
    if pending && Date().timeIntervalSince(changedAt) >= 0.25 { // debounce, like the web page
      pending = false
      check(text)
    }
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
    parts.append("\(d["ms"] as? Int ?? 0) ms")
    overlay.show(verdict: v["label"] as? String ?? "", key: v["key"] as? String ?? "",
                 effort: effortNames[e["level"] as? String ?? ""] ?? "?", shaky: e["shaky"] as? Bool ?? false,
                 detailText: parts.joined(separator: " · "))
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let watcher = Watcher()
watcher.start()
app.run()
