# Prompt Check Live for Windows: grades what you type or dictate into the Claude app's message box,
# in a small overlay pinned just above the box. The Windows twin of PromptCheckLive.swift: it reads
# the box through UI Automation and asks the local Prompt Check server (server.mjs), which holds the
# TypeSafe key. Runs in Windows PowerShell 5.1 (powershell.exe), which every Windows 10/11 machine has;
# the C# below is compiled at startup, so it sticks to C# 5.
$ErrorActionPreference = "Stop"
$log = Join-Path $env:TEMP "prompt-check-live.log"

$src = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Windows.Forms;

public class PromptCheckLive : Form {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

  static readonly string CheckUrl = "http://127.0.0.1:" + (Environment.GetEnvironmentVariable("PORT") ?? "4747") + "/api/check";
  static readonly Dictionary<string, string> EffortNames = new Dictionary<string, string> {
    { "low", "Low" }, { "medium", "Medium" }, { "high", "High" }, { "xhigh", "Extra high" }, { "max", "Max" } };
  static readonly Dictionary<string, string> CheckNames = new Dictionary<string, string> {
    { "goal", "goal" }, { "context", "context" }, { "format", "format" }, { "constraints", "limits" } };

  readonly NotifyIcon tray = new NotifyIcon();
  readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
  readonly JavaScriptSerializer json = new JavaScriptSerializer();
  readonly bool dark;
  readonly float scale;
  readonly Font headFont, detailFont;
  bool paused;
  uint claudePid; DateTime pidCheckedAt = DateTime.MinValue; bool pidIsClaude;
  string lastText = "";
  DateTime changedAt = DateTime.MinValue;
  bool pending;
  int seq;
  WebClient inflight;
  string head = "", rest = "", detail = "";
  Color headColor;

  // Never take focus or clicks from Claude, and stay out of the taskbar and Alt+Tab.
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= 0x8 | 0x20 | 0x80 | 0x08000000; // TOPMOST | TRANSPARENT | TOOLWINDOW | NOACTIVATE
      return cp;
    }
  }

  public PromptCheckLive() {
    object light = Microsoft.Win32.Registry.GetValue(
      @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1);
    dark = light is int && (int)light == 0;
    using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) scale = g.DpiX / 96f;
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    Size = new Size((int)(340 * scale), (int)(50 * scale));
    BackColor = dark ? Color.FromArgb(0x1A, 0x1D, 0x23) : Color.White;
    DoubleBuffered = true;
    headFont = new Font("Segoe UI Semibold", 10f);
    detailFont = new Font("Segoe UI", 8.5f);
    headColor = ForeColor;

    ContextMenu menu = new ContextMenu();
    MenuItem pause = new MenuItem("Pause");
    pause.Click += delegate {
      paused = !paused;
      pause.Text = paused ? "Resume" : "Pause";
      tray.Text = paused ? "Prompt Check Live (paused)" : "Prompt Check Live";
      if (paused) { HideOverlay(); Cancel(); }
    };
    menu.MenuItems.Add(pause);
    menu.MenuItems.Add("-");
    menu.MenuItems.Add("Quit Prompt Check Live", delegate { tray.Visible = false; Application.Exit(); });
    tray.Icon = SystemIcons.Information;
    tray.Text = "Prompt Check Live";
    tray.ContextMenu = menu;
    tray.Visible = true;

    timer.Interval = 200;
    timer.Tick += delegate { Tick(); };
    timer.Start();
  }

  void HideOverlay() { if (Visible) Hide(); }

  bool ClaudeInFront() {
    uint pid;
    GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    if (pid != claudePid || (DateTime.Now - pidCheckedAt).TotalSeconds > 5) {
      claudePid = pid; pidCheckedAt = DateTime.Now;
      try { pidIsClaude = Process.GetProcessById((int)pid).ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase); }
      catch { pidIsClaude = false; }
    }
    return pidIsClaude;
  }

  // The Code tab's message box is labelled "Prompt". Other text boxes in the app are skipped.
  static bool IsMessageBox(AutomationElement el) {
    ControlType ct = el.Current.ControlType;
    if (ct != ControlType.Edit && ct != ControlType.Document) return false;
    string n = (el.Current.Name ?? "").ToLowerInvariant();
    return n.Contains("prompt") || n.Contains("message") || n.Contains("reply");
  }

  static string ReadText(AutomationElement el) {
    object p;
    if (el.TryGetCurrentPattern(TextPattern.Pattern, out p)) return ((TextPattern)p).DocumentRange.GetText(30000) ?? "";
    if (el.TryGetCurrentPattern(ValuePattern.Pattern, out p)) return ((ValuePattern)p).Current.Value ?? "";
    return "";
  }

  void Tick() {
    if (paused || !ClaudeInFront()) { HideOverlay(); return; }
    AutomationElement el;
    string text;
    System.Windows.Rect box;
    try {
      el = AutomationElement.FocusedElement;
      if (el == null || !IsMessageBox(el)) { HideOverlay(); return; }
      text = ReadText(el).Trim();
      box = el.Current.BoundingRectangle;
    } catch { HideOverlay(); return; } // the box went away mid-read
    if (box.IsEmpty) { HideOverlay(); return; }
    if (text.Length == 0) { lastText = ""; pending = false; Cancel(); HideOverlay(); return; }
    if (text != lastText) {
      if (lastText.Length == 0) Message("Checking…", "");
      lastText = text; changedAt = DateTime.Now; pending = true;
    }
    Location = new Point((int)(box.Right - Width), (int)(box.Top - Height - 6 * scale));
    if (!Visible) Show();
    if (pending && (DateTime.Now - changedAt).TotalMilliseconds >= 250) { // debounce, like the web page
      pending = false;
      Check(text);
    }
  }

  void Cancel() { if (inflight != null) { inflight.CancelAsync(); inflight = null; } }

  void Check(string text) {
    Cancel(); // a newer keystroke wins
    int mine = ++seq;
    WebClient wc = new WebClient();
    wc.Encoding = Encoding.UTF8;
    wc.Headers[HttpRequestHeader.ContentType] = "application/json";
    wc.UploadStringCompleted += delegate(object s, UploadStringCompletedEventArgs e) {
      wc.Dispose();
      if (e.Cancelled || mine != seq || paused) return;
      string body = null;
      if (e.Error == null) body = e.Result;
      else {
        WebException we = e.Error as WebException;
        if (we != null && we.Response != null)
          using (StreamReader r = new StreamReader(we.Response.GetResponseStream())) body = r.ReadToEnd();
      }
      if (body == null) { Message("Prompt Check server isn't running", "Double-click Prompt Check Live.cmd"); return; }
      try { Render(json.Deserialize<Dictionary<string, object>>(body)); }
      catch (Exception ex) { Message("Can't read the reply", ex.Message); }
    };
    inflight = wc;
    Dictionary<string, object> req = new Dictionary<string, object>();
    req["prompt"] = text;
    wc.UploadStringAsync(new Uri(CheckUrl), "POST", json.Serialize(req));
  }

  static Dictionary<string, object> Obj(Dictionary<string, object> d, string k) {
    object v; return d.TryGetValue(k, out v) ? v as Dictionary<string, object> : null;
  }
  static string Str(Dictionary<string, object> d, string k) {
    object v; return d != null && d.TryGetValue(k, out v) && v != null ? v.ToString() : "";
  }

  void Render(Dictionary<string, object> d) {
    object err;
    if (d.TryGetValue("error", out err)) { Message("Can't check", err.ToString()); return; }
    Dictionary<string, object> v = Obj(d, "verdict"), e = Obj(d, "effort");
    if (v == null || e == null) return;
    string key = Str(v, "key");
    headColor = key == "ready" ? (dark ? Color.FromArgb(0x4C, 0xC3, 0x8A) : Color.FromArgb(0x1F, 0x7A, 0x4D))
      : key == "missing" ? (dark ? Color.FromArgb(0xF0, 0x71, 0x67) : Color.FromArgb(0xB3, 0x26, 0x1E))
      : (dark ? Color.FromArgb(0xE3, 0xA4, 0x4B) : Color.FromArgb(0xA1, 0x5C, 0x07));
    bool shaky = Str(e, "shaky") == "True";
    string level;
    if (!EffortNames.TryGetValue(Str(e, "level"), out level)) level = "?";
    head = Str(v, "label");
    rest = "  ·  Run at " + level + (shaky ? " (guess)" : "");

    // New tasks list what's missing; replies and questions show the verdict's note instead.
    List<string> parts = new List<string>();
    List<string> missing = new List<string>();
    object m;
    if (d.TryGetValue("missing", out m) && m is IEnumerable)
      foreach (object k in (IEnumerable)m) { string name; if (CheckNames.TryGetValue(k.ToString(), out name)) missing.Add(name); }
    if (missing.Count > 0) parts.Add("Missing: " + string.Join(", ", missing));
    else if (Str(v, "note").Length > 0) parts.Add(Str(v, "note").TrimEnd('.'));
    if (Str(d, "padded") == "True") parts.Add("wordy");
    // Rare and worth surfacing even in this small a space: the model, not just the effort, is wrong.
    string modelHint = Str(d, "modelHint");
    if (modelHint.Length > 0) parts.Add(modelHint);
    parts.Add(Str(d, "ms") + " ms");
    detail = string.Join(" · ", parts);
    Invalidate();
  }

  void Message(string h, string sub) {
    head = h; rest = ""; detail = sub; headColor = dark ? Color.Gainsboro : Color.FromArgb(0x16, 0x18, 0x1D);
    Invalidate();
  }

  protected override void OnPaint(PaintEventArgs pe) {
    Graphics g = pe.Graphics;
    Color muted = dark ? Color.FromArgb(0x9A, 0x9F, 0xAC) : Color.FromArgb(0x5D, 0x62, 0x70);
    Color ink = dark ? Color.FromArgb(0xE9, 0xEA, 0xEE) : Color.FromArgb(0x16, 0x18, 0x1D);
    using (Pen border = new Pen(dark ? Color.FromArgb(0x2C, 0x30, 0x38) : Color.FromArgb(0xD9, 0xDB, 0xE0)))
      g.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
    int pad = (int)(12 * scale);
    TextFormatFlags f = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
    TextRenderer.DrawText(g, head, headFont, new Point(pad, (int)(7 * scale)), headColor, f);
    int w = TextRenderer.MeasureText(g, head, headFont, Size.Empty, f).Width;
    TextRenderer.DrawText(g, rest, headFont, new Point(pad + w, (int)(7 * scale)), rest.Contains("guess") ? muted : ink, f);
    TextRenderer.DrawText(g, detail, detailFont,
      new Rectangle(pad, (int)(28 * scale), Width - 2 * pad, (int)(16 * scale)), muted, f | TextFormatFlags.EndEllipsis);
  }

  public static void Run() {
    bool fresh;
    using (Mutex one = new Mutex(true, "PromptCheckLive", out fresh)) {
      if (!fresh) return; // already running
      SetProcessDPIAware(); // UI Automation reports physical pixels; match them
      ServicePointManager.Expect100Continue = false; // no 350 ms wait per request
      Application.EnableVisualStyles();
      PromptCheckLive overlay = new PromptCheckLive();
      Application.Run();
      GC.KeepAlive(overlay);
    }
  }
}
'@

try {
  $names = "System", "System.Windows.Forms", "System.Drawing", "UIAutomationClient", "UIAutomationTypes", "WindowsBase", "System.Web.Extensions"
  $refs = foreach ($n in $names) { [System.Reflection.Assembly]::LoadWithPartialName($n).Location }
  Add-Type -TypeDefinition $src -ReferencedAssemblies $refs
  [PromptCheckLive]::Run()
} catch {
  $_ | Out-String | Set-Content $log
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show("Prompt Check Live could not start. Details are in $log", "Prompt Check Live") | Out-Null
}
