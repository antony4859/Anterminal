import Foundation

// MARK: - Embedded Server HTML

/// Self-contained web UI served by the embedded HTTP server.
/// The page loads xterm.js from a CDN and connects to /ws/terminal for real
/// interactive PTY sessions streamed over WebSocket.  Workspace state is
/// synced via the existing /ws state channel.
///
/// Layout:
///   - Collapsible sidebar (desktop: always visible, mobile: overlay)
///   - Tab bar for multiple open terminals
///   - Full-viewport xterm.js terminal pane
enum EmbeddedServerHTML {

    // MARK: - Single-Page HTML (inlines CSS + JS)

    // The entire page is a single Swift string literal.
    // xterm.js and its addons are loaded from jsDelivr CDN.
    // NOTE: Swift multi-line strings treat \( as interpolation.
    // JavaScript template literals that use ${ are fine because Swift
    // does not interpret those, but backticks (`) ARE safe inside
    // triple-quoted strings.  We only need to be careful with \(.

    static let indexPage = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="theme-color" content="#1a1a2e">
    <title>anterminal</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5/css/xterm.min.css">
    <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5/lib/xterm.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0/lib/addon-fit.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-links@0/lib/addon-web-links.min.js"></script>
    <style>
    *,*::before,*::after{margin:0;padding:0;box-sizing:border-box}
    html,body{height:100%;overflow:hidden;
      font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;
      background:#1a1a2e;color:#e0e0e0;
      -webkit-font-smoothing:antialiased;
      -webkit-text-size-adjust:100%;
      overscroll-behavior:none;
    }

    /* ---------- layout shell ---------- */
    #app{display:flex;height:100vh;height:100dvh}

    /* ---------- sidebar ---------- */
    #sidebar{
      width:280px;min-width:280px;
      background:#16162a;
      display:flex;flex-direction:column;
      border-right:1px solid #2a2a4a;
      z-index:100;
      transition:transform .25s ease;
    }
    .sidebar-header{
      display:flex;align-items:center;justify-content:space-between;
      padding:14px 16px 10px;border-bottom:1px solid #2a2a4a;
    }
    .sidebar-header h1{font-size:18px;font-weight:700;color:#fff;letter-spacing:-.3px}
    #close-sidebar{
      display:none;background:none;border:none;color:#888;font-size:20px;
      cursor:pointer;width:36px;height:36px;border-radius:8px;
      line-height:36px;text-align:center;
    }
    #close-sidebar:hover{background:#2a2a4a;color:#fff}
    #workspace-list{flex:1;overflow-y:auto;padding:10px 10px 10px 10px;-webkit-overflow-scrolling:touch}

    .ws-card{
      background:#2a2a4a;border-radius:12px;padding:12px 14px;margin-bottom:8px;
      cursor:pointer;border-left:3px solid transparent;
      transition:background .15s,border-color .15s,transform .1s;
      min-height:44px;position:relative;
      -webkit-tap-highlight-color:transparent;
    }
    .ws-card:active{background:#3a3a6a;transform:scale(.98)}
    .ws-card.selected{border-left-color:#6366f1}
    .ws-card .ws-title{
      font-size:14px;font-weight:600;color:#fff;margin-bottom:3px;
      display:flex;align-items:center;gap:6px;line-height:1.3;
    }
    .ws-card .ws-dir{
      font-size:11px;color:#888;
      font-family:'SF Mono','Menlo','Consolas',monospace;
      line-height:1.4;word-break:break-all;
    }
    .ws-card .ws-meta{font-size:11px;color:#666;margin-top:5px;display:flex;gap:10px}
    .ws-card .color-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
    .ws-card .unread-badge{
      background:#3b82f6;color:#fff;font-size:10px;font-weight:600;
      padding:1px 6px;border-radius:10px;min-width:16px;text-align:center;line-height:14px;
    }
    .ws-card .pin-icon{font-size:11px;flex-shrink:0}
    .ws-card .tmux-badge{
      background:#059669;color:#fff;font-size:9px;font-weight:700;
      padding:1px 5px;border-radius:4px;letter-spacing:.3px;text-transform:uppercase;
      flex-shrink:0;
    }

    /* ---------- panel list within workspace cards ---------- */
    .panel-list{
      margin-top:6px;padding:4px 0 0;
      border-top:1px solid rgba(255,255,255,.06);
    }
    .panel-row{
      display:flex;align-items:center;gap:6px;
      padding:4px 6px;border-radius:6px;margin-top:2px;
      cursor:pointer;transition:background .12s;
      font-size:11px;color:#ccc;
      font-family:'SF Mono','Menlo','Consolas',monospace;
    }
    .panel-row:hover{background:rgba(99,102,241,.15)}
    .panel-row:active{background:rgba(99,102,241,.25)}
    .panel-row .panel-tree{color:#555;flex-shrink:0;font-size:10px}
    .panel-row .panel-session{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .panel-row .panel-attached{font-size:9px;color:#888;flex-shrink:0}
    .panel-row .panel-action{
      font-size:8px;font-weight:700;padding:1px 5px;border-radius:3px;
      flex-shrink:0;text-transform:uppercase;letter-spacing:.3px;
    }
    .panel-row .panel-action.mirror{background:#6366f1;color:#fff}
    .panel-row .panel-action.attach{background:#059669;color:#fff}

    /* ---------- tmux sessions sidebar section ---------- */
    .sidebar-section{padding:0 10px 8px}
    .sidebar-section h3{
      font-size:11px;font-weight:600;color:#666;text-transform:uppercase;
      letter-spacing:.5px;padding:8px 4px 4px;
    }
    .tmux-group{margin-bottom:6px}
    .tmux-group-title{
      font-size:11px;font-weight:600;color:#aaa;padding:4px 6px 2px;
    }
    .tmux-item{
      background:#2a2a4a;border-radius:8px;padding:8px 10px;margin-bottom:4px;
      cursor:pointer;transition:background .15s;
      -webkit-tap-highlight-color:transparent;
    }
    .tmux-item:hover{background:#3a3a6a}
    .tmux-item:active{background:#4a4a7a}
    .tmux-name{
      font-size:12px;font-weight:600;color:#e0e0e0;
      font-family:'SF Mono','Menlo','Consolas',monospace;
      display:block;
    }
    .tmux-meta{font-size:10px;color:#888;display:block;margin-top:2px}
    .empty-small{text-align:center;color:#555;font-size:12px;padding:10px 0}

    .sidebar-footer{padding:10px 10px 14px;border-top:1px solid #2a2a4a}
    #new-terminal{
      width:100%;padding:10px;border:none;border-radius:10px;
      background:#6366f1;color:#fff;font-size:13px;font-weight:600;
      cursor:pointer;min-height:44px;transition:background .15s;
    }
    #new-terminal:hover{background:#818cf8}
    #new-terminal:active{background:#4f46e5}

    /* ---------- main area ---------- */
    #main{flex:1;display:flex;flex-direction:column;min-width:0}

    #toolbar{
      display:flex;align-items:center;gap:0;
      height:40px;min-height:40px;
      background:#16162a;border-bottom:1px solid #2a2a4a;
      padding:0 8px;
    }
    #toggle-sidebar{
      display:none;background:none;border:none;color:#e0e0e0;
      font-size:18px;cursor:pointer;width:36px;height:36px;
      border-radius:8px;text-align:center;line-height:36px;flex-shrink:0;
    }
    #toggle-sidebar:hover{background:#2a2a4a}
    #tab-bar{display:flex;gap:2px;flex:1;overflow-x:auto;padding:0 4px;align-items:center}
    #tab-bar::-webkit-scrollbar{display:none}
    .term-tab{
      display:flex;align-items:center;gap:6px;
      padding:6px 12px;border-radius:6px;border:none;
      background:transparent;color:#888;font-size:12px;font-weight:500;
      cursor:pointer;white-space:nowrap;min-height:28px;
      transition:background .12s,color .12s;
      -webkit-tap-highlight-color:transparent;
    }
    .term-tab:hover{background:#2a2a4a;color:#ccc}
    .term-tab.active{background:#2a2a4a;color:#fff;border-bottom:2px solid #6366f1}
    .term-tab .tab-close{
      width:18px;height:18px;line-height:18px;text-align:center;
      border-radius:4px;font-size:12px;color:#666;
    }
    .term-tab .tab-close:hover{background:#3a3a6a;color:#fff}
    #status-indicator{
      width:8px;height:8px;border-radius:50%;flex-shrink:0;margin-left:8px;
      background:#666;transition:background .3s,box-shadow .3s;
    }
    #status-indicator.connected{background:#4ade80;box-shadow:0 0 6px rgba(74,222,128,.6)}

    #terminal-container{flex:1;position:relative;overflow:hidden}
    .terminal-pane{
      position:absolute;top:0;left:0;right:0;bottom:0;
      display:none;
    }
    .terminal-pane.active{display:block}
    .terminal-pane .xterm{height:100%}

    /* empty state when no terminal is open */
    #empty-state{
      display:flex;align-items:center;justify-content:center;
      height:100%;color:#555;font-size:14px;text-align:center;padding:20px;
      flex-direction:column;gap:12px;
    }
    #empty-state .hint{font-size:12px;color:#444}

    /* ---------- mobile responsive ---------- */
    @media(max-width:767px){
      #sidebar{
        position:fixed;top:0;left:0;bottom:0;
        transform:translateX(-100%);
        box-shadow:4px 0 24px rgba(0,0,0,.5);
      }
      #sidebar.open{transform:translateX(0)}
      #close-sidebar{display:block}
      #toggle-sidebar{display:block}
      /* backdrop */
      #sidebar-backdrop{
        display:none;position:fixed;top:0;left:0;right:0;bottom:0;
        background:rgba(0,0,0,.5);z-index:99;
      }
      #sidebar-backdrop.visible{display:block}
    }

    /* touch: make everything 44px minimum */
    @media(pointer:coarse){
      .ws-card{min-height:48px;padding:14px 16px}
      .term-tab{min-height:36px;padding:8px 14px}
    }

    /* ---------- sidebar settings footer ---------- */
    .sidebar-settings-footer{
      padding:8px 10px 10px;border-top:1px solid #2a2a4a;
      display:flex;align-items:center;justify-content:flex-end;
    }
    .settings-gear-btn{
      background:none;border:none;color:#666;font-size:16px;
      cursor:pointer;width:32px;height:32px;border-radius:8px;
      display:flex;align-items:center;justify-content:center;
      transition:background .15s,color .15s;
    }
    .settings-gear-btn:hover{background:#2a2a4a;color:#fff}

    /* settings overlay */
    #settings-overlay{
      display:none;position:fixed;top:0;left:0;right:0;bottom:0;
      background:rgba(0,0,0,.6);z-index:200;
      align-items:center;justify-content:center;
    }
    #settings-overlay.open{display:flex}
    .settings-panel{
      background:#1e1e3a;border-radius:16px;padding:24px;
      width:320px;max-width:90vw;box-shadow:0 12px 40px rgba(0,0,0,.5);
      border:1px solid #2a2a4a;
    }
    .settings-panel h2{
      font-size:16px;font-weight:700;color:#fff;margin-bottom:16px;
      display:flex;align-items:center;justify-content:space-between;
    }
    .settings-panel .settings-close{
      background:none;border:none;color:#888;font-size:18px;
      cursor:pointer;width:28px;height:28px;border-radius:6px;
      line-height:28px;text-align:center;
    }
    .settings-panel .settings-close:hover{background:#2a2a4a;color:#fff}
    .settings-row{
      display:flex;justify-content:space-between;align-items:center;
      padding:8px 0;border-bottom:1px solid rgba(255,255,255,.05);
      font-size:13px;
    }
    .settings-row .settings-label{color:#888}
    .settings-row .settings-value{color:#e0e0e0;font-weight:500}
    .settings-disconnect{
      width:100%;padding:10px;border:none;border-radius:10px;
      background:#ef4444;color:#fff;font-size:13px;font-weight:600;
      cursor:pointer;margin-top:16px;min-height:44px;transition:background .15s;
    }
    .settings-disconnect:hover{background:#dc2626}
    .settings-disconnect:active{background:#b91c1c}

    /* reconnecting overlay */
    .reconnect-overlay{
      position:absolute;top:0;left:0;right:0;bottom:0;
      background:rgba(26,26,46,.85);
      display:flex;align-items:center;justify-content:center;
      flex-direction:column;gap:8px;z-index:10;
      color:#888;font-size:14px;
    }
    .reconnect-overlay .spinner{
      width:24px;height:24px;border:3px solid #333;border-top-color:#6366f1;
      border-radius:50%;animation:spin .8s linear infinite;
    }
    @keyframes spin{to{transform:rotate(360deg)}}

    /* animation */
    @keyframes fadeIn{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:translateY(0)}}
    .ws-card{animation:fadeIn .2s ease-out}
    </style>
    </head>
    <body>
    <div id="sidebar-backdrop" onclick="app.closeSidebar()"></div>
    <div id="settings-overlay" onclick="app.closeSettings(event)">
      <div class="settings-panel" onclick="event.stopPropagation()">
        <h2>Settings <button class="settings-close" onclick="app.closeSettings()">&times;</button></h2>
        <div class="settings-row"><span class="settings-label">Server Port</span><span class="settings-value" id="settings-port">--</span></div>
        <div class="settings-row"><span class="settings-label">Connected Clients</span><span class="settings-value" id="settings-clients">--</span></div>
        <div class="settings-row"><span class="settings-label">App Version</span><span class="settings-value" id="settings-version">--</span></div>
        <button class="settings-disconnect" onclick="app.disconnectAll()">Disconnect All Tabs</button>
      </div>
    </div>
    <div id="app">
      <aside id="sidebar">
        <div class="sidebar-header">
          <h1>anterminal</h1>
          <button id="close-sidebar" onclick="app.closeSidebar()">&times;</button>
        </div>
        <div id="workspace-list"></div>
        <div class="sidebar-section" id="tmux-section" style="display:none">
          <h3>Tmux Sessions</h3>
          <div id="tmux-sessions"></div>
        </div>
        <div class="sidebar-footer">
          <button id="new-terminal" onclick="app.openDefaultTerminal()">+ New Terminal</button>
        </div>
        <div class="sidebar-settings-footer">
          <button class="settings-gear-btn" onclick="app.openSettings()" title="Settings">&#9881;</button>
        </div>
      </aside>
      <main id="main">
        <div id="toolbar">
          <button id="toggle-sidebar" onclick="app.toggleSidebar()">&#9776;</button>
          <div id="tab-bar"></div>
          <div id="status-indicator"></div>
        </div>
        <div id="terminal-container">
          <div id="empty-state">
            <div>Select a workspace to open a terminal</div>
            <div class="hint">or press "+ New Terminal"</div>
          </div>
        </div>
      </main>
    </div>
    <script>
    (function(){
    'use strict';

    /* ============================================================
       TerminalTab  -- one xterm.js instance + one WebSocket to /ws/terminal
       ============================================================ */
    function TerminalTab(workspaceId, directory, title, tmuxSession, panelLabel) {
        this.id = 'tab-' + Math.random().toString(36).substr(2,9);
        this.workspaceId = workspaceId;
        this.directory = directory;
        this.title = title;
        this.tmuxSession = tmuxSession || null;
        this.panelLabel = panelLabel || null;
        this.ws = null;
        this.initialized = false;
        this.sessionId = null;         // PTY session ID from server
        this.reconnectDelay = 1000;    // exponential backoff starting at 1s
        this.reconnectTimer = null;
        this.closed = false;           // true after explicit user close

        this.terminal = new Terminal({
            theme: {
                background:  '#1a1a2e',
                foreground:  '#e0e0e0',
                cursor:      '#6366f1',
                cursorAccent:'#1a1a2e',
                selectionBackground: 'rgba(99,102,241,0.3)',
                selectionForeground: '#ffffff',
                black:   '#1a1a2e',
                red:     '#ef4444',
                green:   '#4ade80',
                yellow:  '#fbbf24',
                blue:    '#3b82f6',
                magenta: '#a78bfa',
                cyan:    '#22d3ee',
                white:   '#e0e0e0',
                brightBlack:   '#555577',
                brightRed:     '#f87171',
                brightGreen:   '#86efac',
                brightYellow:  '#fde68a',
                brightBlue:    '#60a5fa',
                brightMagenta: '#c4b5fd',
                brightCyan:    '#67e8f9',
                brightWhite:   '#ffffff'
            },
            fontSize: 14,
            fontFamily: "'SF Mono','Menlo','Monaco','Consolas',monospace",
            cursorBlink: true,
            allowTransparency: true,
            scrollback: 5000,
            convertEol: false
        });

        this.fitAddon = new FitAddon.FitAddon();
        this.terminal.loadAddon(this.fitAddon);
        this.terminal.loadAddon(new WebLinksAddon.WebLinksAddon());

        this.containerEl = document.createElement('div');
        this.containerEl.className = 'terminal-pane';
        this.containerEl.id = this.id;
    }

    TerminalTab.prototype.open = function(parentEl) {
        parentEl.appendChild(this.containerEl);
        this.terminal.open(this.containerEl);
        // Small delay so the DOM has settled before we measure.
        var self = this;
        requestAnimationFrame(function(){ self.fitAddon.fit(); });
        this.connect();
    };

    TerminalTab.prototype.connect = function() {
        var self = this;
        var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        this.ws = new WebSocket(proto + '//' + location.host + '/ws/terminal');

        this.ws.onopen = function() {
            self.reconnectDelay = 1000; // reset backoff on successful connect
            self.hideReconnectOverlay();
            if (self.sessionId) {
                // Try to reconnect to the same PTY session.
                self.ws.send(JSON.stringify({ type: 'reconnect', sessionId: self.sessionId }));
            } else {
                // Fresh init.
                var dims = self.fitAddon.proposeDimensions();
                var initMsg = {
                    type: 'init',
                    dir:  self.directory,
                    cols: dims ? dims.cols : 80,
                    rows: dims ? dims.rows : 24
                };
                if (self.tmuxSession) {
                    initMsg.tmux = self.tmuxSession;
                }
                self.ws.send(JSON.stringify(initMsg));
            }
            self.initialized = true;
        };

        this.ws.onmessage = function(e) {
            try {
                var msg = JSON.parse(e.data);
                if (msg.type === 'session_created') {
                    self.sessionId = msg.sessionId;
                    return;
                }
                if (msg.type === 'reconnected') {
                    self.sessionId = msg.sessionId;
                    self.hideReconnectOverlay();
                    return;
                }
                if (msg.type === 'reconnect_failed') {
                    // Server lost our session; do a fresh init.
                    self.sessionId = null;
                    var dims = self.fitAddon.proposeDimensions();
                    var initMsg = {
                        type: 'init',
                        dir:  self.directory,
                        cols: dims ? dims.cols : 80,
                        rows: dims ? dims.rows : 24
                    };
                    if (self.tmuxSession) {
                        initMsg.tmux = self.tmuxSession;
                    }
                    self.ws.send(JSON.stringify(initMsg));
                    return;
                }
                if (msg.type === 'ping') {
                    // Respond with pong.
                    if (self.ws && self.ws.readyState === WebSocket.OPEN) {
                        self.ws.send(JSON.stringify({ type: 'pong' }));
                    }
                    return;
                }
            } catch(ignored) {}
            // Regular terminal output.
            self.terminal.write(e.data);
        };

        this.ws.onclose = function() {
            if (self.closed) return; // user explicitly closed
            // Show reconnecting overlay and attempt reconnection.
            self.showReconnectOverlay();
            self.scheduleReconnect();
        };

        this.ws.onerror = function() {};

        // Only bind terminal event handlers once (on first connect).
        if (!this._termEventsAttached) {
            this._termEventsAttached = true;
            this.terminal.onData(function(data) {
                if (self.ws && self.ws.readyState === WebSocket.OPEN) {
                    self.ws.send(JSON.stringify({ type: 'input', data: data }));
                }
            });

            this.terminal.onResize(function(size) {
                if (self.ws && self.ws.readyState === WebSocket.OPEN) {
                    self.ws.send(JSON.stringify({ type: 'resize', cols: size.cols, rows: size.rows }));
                }
            });
        }
    };

    TerminalTab.prototype.scheduleReconnect = function() {
        var self = this;
        if (self.closed) return;
        self.reconnectTimer = setTimeout(function() {
            if (self.closed) return;
            self.connect();
        }, self.reconnectDelay);
        // Exponential backoff: 1s, 2s, 4s, 8s, 10s (capped)
        self.reconnectDelay = Math.min(self.reconnectDelay * 2, 10000);
    };

    TerminalTab.prototype.showReconnectOverlay = function() {
        if (this.containerEl.querySelector('.reconnect-overlay')) return;
        var overlay = document.createElement('div');
        overlay.className = 'reconnect-overlay';
        overlay.innerHTML = '<div class="spinner"></div><div>Reconnecting...</div>';
        this.containerEl.appendChild(overlay);
    };

    TerminalTab.prototype.hideReconnectOverlay = function() {
        var overlay = this.containerEl.querySelector('.reconnect-overlay');
        if (overlay) overlay.parentNode.removeChild(overlay);
    };

    TerminalTab.prototype.fit = function() {
        try { this.fitAddon.fit(); } catch(e) {}
    };

    TerminalTab.prototype.show = function() {
        this.containerEl.classList.add('active');
        var self = this;
        requestAnimationFrame(function(){
            self.fit();
            self.terminal.focus();
        });
    };

    TerminalTab.prototype.hide = function() {
        this.containerEl.classList.remove('active');
    };

    TerminalTab.prototype.close = function() {
        this.closed = true;
        if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
        if (this.ws) { this.ws.close(); this.ws = null; }
        this.terminal.dispose();
        if (this.containerEl.parentNode) this.containerEl.parentNode.removeChild(this.containerEl);
    };

    /* ============================================================
       App  -- manages tabs, sidebar, state WebSocket
       ============================================================ */
    function App() {
        this.tabs = [];
        this.activeTab = null;
        this.stateWs = null;
        this.workspaces = [];
        this.reconnectDelay = 1000;
        this._tmuxSessionData = [];
        this._lastStateJson = '';
        this._lastWorkspacesHtml = '';
        this._lastTmuxHtml = '';
        this._lastTabsHtml = '';
    }

    App.prototype.init = function() {
        this.connectState();
        this.fetchWorkspaces();
        var self = this;
        window.addEventListener('resize', function() {
            if (self.activeTab) self.activeTab.fit();
        });
    };

    /* ---- state WebSocket ---- */
    App.prototype.connectState = function() {
        var self = this;
        var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        this.stateWs = new WebSocket(proto + '//' + location.host + '/ws');

        this.stateWs.onopen = function() {
            document.getElementById('status-indicator').className = 'connected';
            self.reconnectDelay = 1000;
        };
        this.stateWs.onclose = function() {
            document.getElementById('status-indicator').className = '';
            setTimeout(function(){ self.connectState(); }, self.reconnectDelay);
            self.reconnectDelay = Math.min(self.reconnectDelay * 1.5, 15000);
        };
        this.stateWs.onerror = function(){};
        this.stateWs.onmessage = function(e) {
            try {
                var msg = JSON.parse(e.data);
                if (msg.type === 'ping') {
                    // Respond with pong on the state WebSocket too.
                    if (self.stateWs && self.stateWs.readyState === WebSocket.OPEN) {
                        self.stateWs.send(JSON.stringify({ type: 'pong' }));
                    }
                    return;
                }
                if (msg.type === 'state') {
                    var newData = JSON.stringify(msg.data || []);
                    if (newData !== self._lastStateJson) {
                        self._lastStateJson = newData;
                        self.workspaces = msg.data || [];
                        self.renderWorkspaces();
                    }
                    // Update tmux sessions from the state broadcast.
                    if (msg.tmuxSessions) {
                        self.renderTmuxSessions(msg.tmuxSessions);
                    }
                }
            } catch(err) {}
        };
    };

    App.prototype.fetchWorkspaces = function() {
        var self = this;
        fetch('/api/workspaces').then(function(r){ return r.json(); }).then(function(data){
            self.workspaces = data;
            self.renderWorkspaces();
        }).catch(function(){});
    };

    /* ---- sidebar ---- */
    App.prototype.toggleSidebar = function() {
        var sb = document.getElementById('sidebar');
        var bd = document.getElementById('sidebar-backdrop');
        sb.classList.toggle('open');
        bd.classList.toggle('visible');
    };

    App.prototype.closeSidebar = function() {
        document.getElementById('sidebar').classList.remove('open');
        document.getElementById('sidebar-backdrop').classList.remove('visible');
    };

    /* ---- workspaces rendering ---- */
    App.prototype.renderWorkspaces = function() {
        var el = document.getElementById('workspace-list');
        if (!this.workspaces.length) {
            var emptyHtml = '<div style="text-align:center;color:#555;padding:30px 10px;font-size:13px">No workspaces open</div>';
            if (emptyHtml !== this._lastWorkspacesHtml) {
                this._lastWorkspacesHtml = emptyHtml;
                el.innerHTML = emptyHtml;
            }
            return;
        }
        var self = this;
        var newHtml = this.workspaces.map(function(w) {
            var colorDot = w.color
                ? '<span class="color-dot" style="background:' + esc(w.color) + '"></span>' : '';
            var pin = w.isPinned ? '<span class="pin-icon">&#128204;</span>' : '';
            var badge = w.unreadCount > 0
                ? '<span class="unread-badge">' + w.unreadCount + '</span>' : '';
            var sel = w.isSelected ? ' selected' : '';
            // Check if a tab is open for this workspace
            var hasTab = self.tabs.some(function(t){ return t.workspaceId === w.id; });
            var openDot = hasTab ? '<span style="width:6px;height:6px;border-radius:50%;background:#6366f1;flex-shrink:0"></span>' : '';
            // Check if any panel has a tmux session
            var tmuxPanels = (w.panels || []).filter(function(p){ return !!p.tmuxSession; });
            var hasTmux = tmuxPanels.length > 0;
            var tmuxBadge = hasTmux ? '<span class="tmux-badge">TMUX</span>' : '';
            // Store first tmux session name for quick attach
            var firstTmux = tmuxPanels.length > 0 ? tmuxPanels[0] : null;
            var tmuxAttr = firstTmux ? ' data-tmux="' + esc(firstTmux.tmuxSession) + '"' : '';

            var cardHtml = '<div class="ws-card' + sel + '" data-id="' + esc(w.id) + '" data-dir="' + esc(w.directory) + '" data-title="' + esc(w.title) + '"' + tmuxAttr + '>'
                + '<div class="ws-title">' + colorDot + pin + esc(w.title) + badge + tmuxBadge + openDot + '</div>'
                + '<div class="ws-dir">' + esc(w.directory) + '</div>'
                + '<div class="ws-meta"><span>' + w.panelCount + ' panel' + (w.panelCount !== 1 ? 's' : '') + '</span></div>';

            // Show per-panel tmux session list for tmux workspaces
            if (hasTmux && tmuxPanels.length > 0) {
                cardHtml += '<div class="panel-list">';
                for (var pi = 0; pi < tmuxPanels.length; pi++) {
                    var p = tmuxPanels[pi];
                    var isLast = (pi === tmuxPanels.length - 1);
                    var tree = isLast ? '&#9492;&#9472;&#9472;' : '&#9500;&#9472;&#9472;';
                    // Check if we have a tab mirroring this specific tmux session
                    var isMirrored = self.tabs.some(function(t){ return t.tmuxSession === p.tmuxSession; });
                    var actionCls = isMirrored ? 'mirror' : 'attach';
                    var actionText = isMirrored ? 'MIRROR' : 'Attach';
                    var attachedInfo = '';
                    // Look up attached count from tmux session data if available
                    if (self._tmuxSessionData) {
                        var tmuxInfo = self._tmuxSessionData.find(function(s){ return s.name === p.tmuxSession; });
                        if (tmuxInfo) {
                            attachedInfo = '<span class="panel-attached">(' + tmuxInfo.attached + ' attached)</span>';
                        }
                    }
                    cardHtml += '<div class="panel-row" data-panel-tmux="' + esc(p.tmuxSession) + '" data-panel-idx="' + (pi + 1) + '">'
                        + '<span class="panel-tree">' + tree + '</span>'
                        + '<span class="panel-session">Panel ' + (pi + 1) + ': ' + esc(p.tmuxSession) + '</span>'
                        + attachedInfo
                        + '<span class="panel-action ' + actionCls + '">' + actionText + '</span>'
                        + '</div>';
                }
                cardHtml += '</div>';
            }
            cardHtml += '</div>';
            return cardHtml;
        }).join('');

        // Only update DOM if the HTML actually changed
        if (newHtml === this._lastWorkspacesHtml) { return; }
        this._lastWorkspacesHtml = newHtml;
        el.innerHTML = newHtml;

        // Click handlers for workspace cards (header area)
        el.querySelectorAll('.ws-card').forEach(function(card) {
            // Click handler for the card itself (not panel rows)
            card.addEventListener('click', function(e) {
                // If the click was on a panel row, handle that separately
                // Walk up to find panel-row (avoid .closest for ES5 compat)
                var panelRow = e.target;
                while (panelRow && panelRow !== card && !panelRow.classList.contains('panel-row')) {
                    panelRow = panelRow.parentNode;
                }
                if (panelRow === card) panelRow = null;
                if (panelRow) {
                    e.stopPropagation();
                    var panelTmux = panelRow.getAttribute('data-panel-tmux');
                    var panelIdx = panelRow.getAttribute('data-panel-idx');
                    var id = card.getAttribute('data-id');
                    var dir = card.getAttribute('data-dir');
                    var title = card.getAttribute('data-title');
                    self.openTerminal({
                        id: id + '-panel-' + panelIdx,
                        directory: dir,
                        title: title,
                        tmuxSession: panelTmux,
                        panelLabel: 'Panel ' + panelIdx
                    });
                    return;
                }
                var id = card.getAttribute('data-id');
                var dir = card.getAttribute('data-dir');
                var title = card.getAttribute('data-title');
                var tmux = card.getAttribute('data-tmux') || null;
                self.openTerminal({ id: id, directory: dir, title: title, tmuxSession: tmux });
            });
        });
    };

    /* ---- terminal tab management ---- */
    App.prototype.openTerminal = function(workspace) {
        // If a tab already exists for this workspace (or same tmux session), just activate it.
        var existing = null;
        for (var i = 0; i < this.tabs.length; i++) {
            // For tmux panel tabs, match by tmux session name
            if (workspace.tmuxSession && this.tabs[i].tmuxSession === workspace.tmuxSession) {
                existing = this.tabs[i]; break;
            }
            // For non-tmux or workspace-level tabs, match by workspace id
            if (this.tabs[i].workspaceId === workspace.id) { existing = this.tabs[i]; break; }
        }
        if (existing) {
            this.activateTab(existing);
            this.closeSidebarIfMobile();
            return;
        }

        // Hide the empty state.
        var empty = document.getElementById('empty-state');
        if (empty) empty.style.display = 'none';

        var tab = new TerminalTab(workspace.id, workspace.directory, workspace.title, workspace.tmuxSession, workspace.panelLabel || null);
        this.tabs.push(tab);
        tab.open(document.getElementById('terminal-container'));
        this.activateTab(tab);
        this.renderTabs();
        this.renderWorkspaces(); // update open-dot
        this.closeSidebarIfMobile();
    };

    App.prototype.openDefaultTerminal = function() {
        // Open a terminal in the home directory, not tied to a workspace.
        var homeDir = '~';
        // Try to use the first workspace's directory, or fall back.
        if (this.workspaces.length > 0) {
            var sel = this.workspaces.find(function(w){ return w.isSelected; });
            if (sel) { this.openTerminal({ id: sel.id, directory: sel.directory, title: sel.title }); return; }
        }
        var fakeId = 'home-' + Math.random().toString(36).substr(2,6);
        this.openTerminal({ id: fakeId, directory: homeDir, title: 'Terminal' });
    };

    App.prototype.activateTab = function(tab) {
        for (var i = 0; i < this.tabs.length; i++) this.tabs[i].hide();
        tab.show();
        this.activeTab = tab;
        this.renderTabs();
    };

    App.prototype.closeTab = function(tab) {
        tab.close();
        this.tabs = this.tabs.filter(function(t){ return t !== tab; });
        if (this.activeTab === tab) {
            this.activeTab = this.tabs.length > 0 ? this.tabs[this.tabs.length - 1] : null;
            if (this.activeTab) this.activeTab.show();
        }
        this.renderTabs();
        this.renderWorkspaces();
        // Show empty state if no tabs remain.
        if (this.tabs.length === 0) {
            var empty = document.getElementById('empty-state');
            if (empty) empty.style.display = '';
        }
    };

    App.prototype.renderTabs = function() {
        var bar = document.getElementById('tab-bar');
        var self = this;
        var newHtml = this.tabs.map(function(t) {
            var cls = t === self.activeTab ? 'term-tab active' : 'term-tab';
            var tmuxIndicator = t.tmuxSession ? '<span class="tmux-badge" style="font-size:8px;padding:0 4px;margin-right:2px">MIRROR</span>' : '';
            var tabTitle = esc(t.title);
            if (t.panelLabel) {
                tabTitle = esc(t.title) + ' / ' + esc(t.panelLabel);
            }
            return '<button class="' + cls + '" data-tab-id="' + t.id + '">'
                + tmuxIndicator
                + '<span>' + tabTitle + '</span>'
                + '<span class="tab-close" data-close="' + t.id + '">&times;</span>'
                + '</button>';
        }).join('');

        // Only update DOM if the HTML actually changed
        if (newHtml === this._lastTabsHtml) { return; }
        this._lastTabsHtml = newHtml;
        bar.innerHTML = newHtml;

        // Wire up click handlers.
        bar.querySelectorAll('.term-tab').forEach(function(el) {
            el.addEventListener('click', function(e) {
                // If the close button was clicked, close the tab.
                if (e.target.hasAttribute('data-close')) {
                    var cid = e.target.getAttribute('data-close');
                    var ct = self.tabs.find(function(t){ return t.id === cid; });
                    if (ct) self.closeTab(ct);
                    return;
                }
                var tid = el.getAttribute('data-tab-id');
                var tt = self.tabs.find(function(t){ return t.id === tid; });
                if (tt) self.activateTab(tt);
            });
        });
    };

    App.prototype.closeSidebarIfMobile = function() {
        if (window.innerWidth < 768) this.closeSidebar();
    };

    /* ---- tmux sessions ---- */
    App.prototype.loadTmuxSessions = function() {
        var self = this;
        fetch('/api/tmux/sessions').then(function(r){ return r.json(); }).then(function(data){
            self.renderTmuxSessions(data);
        }).catch(function(){});
    };

    App.prototype.renderTmuxSessions = function(sessions) {
        var section = document.getElementById('tmux-section');
        var el = document.getElementById('tmux-sessions');
        // Store session data for panel list rendering
        this._tmuxSessionData = sessions || [];
        if (!sessions || !sessions.length) {
            section.style.display = 'none';
            if ('' !== this._lastTmuxHtml) {
                this._lastTmuxHtml = '';
                el.innerHTML = '';
            }
            return;
        }
        section.style.display = '';
        var self = this;

        // Group sessions by workspace: find which workspace each session belongs to
        var grouped = {};  // workspaceTitle -> [{session, workspaceId}]
        var ungrouped = [];
        for (var si = 0; si < sessions.length; si++) {
            var s = sessions[si];
            var foundWs = null;
            for (var wi = 0; wi < self.workspaces.length; wi++) {
                var w = self.workspaces[wi];
                var wPanels = w.panels || [];
                for (var pi = 0; pi < wPanels.length; pi++) {
                    if (wPanels[pi].tmuxSession === s.name) {
                        foundWs = w;
                        break;
                    }
                }
                if (foundWs) break;
            }
            if (foundWs) {
                var key = foundWs.id;
                if (!grouped[key]) {
                    grouped[key] = { title: foundWs.title, sessions: [] };
                }
                grouped[key].sessions.push(s);
            } else {
                ungrouped.push(s);
            }
        }

        var html = '';
        // Render grouped sessions
        var groupKeys = Object.keys(grouped);
        for (var gi = 0; gi < groupKeys.length; gi++) {
            var group = grouped[groupKeys[gi]];
            html += '<div class="tmux-group">';
            html += '<div class="tmux-group-title">' + esc(group.title) + '</div>';
            for (var gsi = 0; gsi < group.sessions.length; gsi++) {
                var gs = group.sessions[gsi];
                html += '<div class="tmux-item" data-tmux-name="' + esc(gs.name) + '">'
                    + '<span class="tmux-name">' + esc(gs.name) + '</span>'
                    + '<span class="tmux-meta">' + gs.attached + ' attached &middot; ' + gs.windowCount + ' win</span>'
                    + '</div>';
            }
            html += '</div>';
        }
        // Render ungrouped sessions
        if (ungrouped.length > 0) {
            html += '<div class="tmux-group">';
            if (groupKeys.length > 0) {
                html += '<div class="tmux-group-title">Other</div>';
            }
            for (var ui = 0; ui < ungrouped.length; ui++) {
                var us = ungrouped[ui];
                html += '<div class="tmux-item" data-tmux-name="' + esc(us.name) + '">'
                    + '<span class="tmux-name">' + esc(us.name) + '</span>'
                    + '<span class="tmux-meta">' + us.attached + ' attached &middot; ' + us.windowCount + ' win</span>'
                    + '</div>';
            }
            html += '</div>';
        }

        // Only update DOM if the HTML actually changed
        if (html === this._lastTmuxHtml) { return; }
        this._lastTmuxHtml = html;
        el.innerHTML = html;
        el.querySelectorAll('.tmux-item').forEach(function(item) {
            item.addEventListener('click', function() {
                var name = item.getAttribute('data-tmux-name');
                self.attachToTmux(name);
            });
        });
    };

    App.prototype.attachToTmux = function(sessionName) {
        // Check if we already have a tab attached to this tmux session.
        var existing = null;
        for (var i = 0; i < this.tabs.length; i++) {
            if (this.tabs[i].tmuxSession === sessionName) { existing = this.tabs[i]; break; }
        }
        if (existing) {
            this.activateTab(existing);
            this.closeSidebarIfMobile();
            return;
        }

        // Hide the empty state.
        var empty = document.getElementById('empty-state');
        if (empty) empty.style.display = 'none';

        var tab = new TerminalTab('tmux-' + sessionName, '~', sessionName, sessionName);
        this.tabs.push(tab);
        tab.open(document.getElementById('terminal-container'));
        this.activateTab(tab);
        this.renderTabs();
        this.closeSidebarIfMobile();
    };

    /* ---- settings panel ---- */
    App.prototype.openSettings = function() {
        var self = this;
        // Populate settings with current info
        document.getElementById('settings-port').textContent = location.port || '80';
        document.getElementById('settings-clients').textContent = '--';
        document.getElementById('settings-version').textContent = '--';
        // Fetch server status for live data
        fetch('/api/status').then(function(r){ return r.json(); }).then(function(data) {
            if (data.connectedClients !== undefined) {
                document.getElementById('settings-clients').textContent = data.connectedClients;
            }
            if (data.version) {
                document.getElementById('settings-version').textContent = data.version;
            }
            if (data.port) {
                document.getElementById('settings-port').textContent = data.port;
            }
        }).catch(function(){});
        document.getElementById('settings-overlay').classList.add('open');
    };

    App.prototype.closeSettings = function(e) {
        if (e && e.target && e.target.id !== 'settings-overlay') { return; }
        document.getElementById('settings-overlay').classList.remove('open');
    };

    App.prototype.disconnectAll = function() {
        // Close all open terminal tabs
        var tabsCopy = this.tabs.slice();
        for (var i = 0; i < tabsCopy.length; i++) {
            this.closeTab(tabsCopy[i]);
        }
        this.closeSettings();
    };

    /* ---- helpers ---- */
    function esc(s) {
        if (!s) return '';
        var d = document.createElement('div');
        d.appendChild(document.createTextNode(s));
        return d.innerHTML;
    }

    /* ---- bootstrap ---- */
    var appInstance = new App();
    window.app = appInstance;
    appInstance.init();
    // Load tmux sessions once on startup; subsequent updates come via state broadcast.
    appInstance.loadTmuxSessions();
    })();
    </script>
    </body>
    </html>
    """

    // Legacy separate CSS/JS kept as empty stubs so existing /style.css and /app.js
    // routes don't 404 if a stale browser tab tries to fetch them.
    static let styleCSS = "/* styles are inlined in the HTML */"
    static let appJS = "/* scripts are inlined in the HTML */"
}
