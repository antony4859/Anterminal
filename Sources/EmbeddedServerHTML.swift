import Foundation

// MARK: - Embedded Server HTML

/// Self-contained web UI served by the embedded HTTP server.
/// The page loads xterm.js from a CDN and connects to /ws/terminal for real
/// interactive PTY sessions streamed over WebSocket.  Workspace state is
/// synced via the existing /ws state channel.
///
/// Layout:
///   - Collapsible sidebar matching native app (compact rows with pin, tmux badge, unread, close)
///   - Tab bar with indigo active highlight and hover close buttons
///   - Split view support for tmux workspaces with resizable divider
///   - Notification bell with unread badge and dropdown panel
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
      width:260px;min-width:260px;
      background:rgba(20,20,38,0.92);
      backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);
      display:flex;flex-direction:column;
      border-right:1px solid rgba(255,255,255,0.06);
      z-index:100;
      transition:transform .25s ease;
    }
    .sidebar-header{
      display:flex;align-items:center;justify-content:space-between;
      padding:12px 14px 8px;border-bottom:1px solid rgba(255,255,255,0.06);
    }
    .sidebar-header h1{font-size:15px;font-weight:700;color:#fff;letter-spacing:-.3px}
    #close-sidebar{
      display:none;background:none;border:none;color:#888;font-size:20px;
      cursor:pointer;width:32px;height:32px;border-radius:6px;
      line-height:32px;text-align:center;
    }
    #close-sidebar:hover{background:rgba(255,255,255,0.08);color:#fff}
    #workspace-list{
      flex:1;overflow-y:auto;padding:6px 8px;
      -webkit-overflow-scrolling:touch;
    }
    #workspace-list::-webkit-scrollbar{width:4px}
    #workspace-list::-webkit-scrollbar-track{background:transparent}
    #workspace-list::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.1);border-radius:2px}

    /* ---------- workspace row (compact, native-matching) ---------- */
    .ws-row{
      display:flex;align-items:flex-start;gap:0;
      padding:7px 10px 7px 0;margin:0;
      cursor:pointer;border-radius:6px;
      border-left:3px solid transparent;
      transition:background .12s,border-color .12s;
      position:relative;
      -webkit-tap-highlight-color:transparent;
    }
    .ws-row:hover{background:rgba(255,255,255,0.04)}
    .ws-row:active{background:rgba(255,255,255,0.07)}
    .ws-row.selected{border-left-color:#6366f1;background:rgba(99,102,241,0.08)}
    .ws-row .ws-left{
      display:flex;flex-direction:column;flex:1;min-width:0;padding-left:10px;
    }
    .ws-row .ws-top-line{
      display:flex;align-items:center;gap:5px;min-height:18px;
    }
    .ws-row .ws-title{
      font-size:12.5px;font-weight:600;color:#e8e8f0;
      white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
      flex:1;min-width:0;line-height:1.3;
    }
    .ws-row.selected .ws-title{color:#fff}
    .ws-row .ws-dir{
      font-size:10px;color:rgba(255,255,255,0.35);
      font-family:'SF Mono','Menlo','Consolas',monospace;
      line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
      margin-top:1px;
    }
    .ws-row .ws-meta-line{
      display:flex;align-items:center;gap:6px;margin-top:2px;
      font-size:10px;color:rgba(255,255,255,0.3);
    }

    /* badges and icons */
    .ws-row .unread-badge{
      background:#6366f1;color:#fff;font-size:9px;font-weight:600;
      width:16px;height:16px;border-radius:50%;
      display:flex;align-items:center;justify-content:center;
      line-height:1;flex-shrink:0;
    }
    .ws-row .pin-icon{
      font-size:9px;color:rgba(255,255,255,0.45);flex-shrink:0;
      display:flex;align-items:center;
    }
    .ws-row .tmux-badge{
      background:rgba(5,150,105,0.8);color:#fff;font-size:8px;font-weight:700;
      padding:1px 4px;border-radius:3px;letter-spacing:.3px;text-transform:uppercase;
      flex-shrink:0;line-height:1.2;
    }
    .ws-row .color-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
    .ws-row .open-dot{
      width:5px;height:5px;border-radius:50%;background:#6366f1;flex-shrink:0;
    }
    .ws-row .panel-count{
      font-size:10px;color:rgba(255,255,255,0.3);flex-shrink:0;
    }
    .ws-row .ws-close{
      opacity:0;background:none;border:none;color:rgba(255,255,255,0.4);
      font-size:11px;cursor:pointer;width:18px;height:18px;border-radius:4px;
      display:flex;align-items:center;justify-content:center;
      flex-shrink:0;transition:opacity .12s,background .12s,color .12s;
      margin-top:1px;
    }
    .ws-row:hover .ws-close{opacity:1}
    .ws-row .ws-close:hover{background:rgba(255,255,255,0.1);color:#fff}

    /* ---------- new workspace button area ---------- */
    .sidebar-footer{padding:8px;border-top:1px solid rgba(255,255,255,0.06)}
    .new-ws-btn-group{display:flex;gap:4px}
    .new-ws-btn{
      flex:1;padding:8px;border:none;border-radius:8px;
      background:rgba(99,102,241,0.15);color:#a5b4fc;
      font-size:12px;font-weight:600;cursor:pointer;
      min-height:36px;transition:background .12s,color .12s;
      display:flex;align-items:center;justify-content:center;gap:4px;
    }
    .new-ws-btn:hover{background:rgba(99,102,241,0.25);color:#c7d2fe}
    .new-ws-btn:active{background:rgba(99,102,241,0.35)}
    .new-ws-btn.primary{
      background:#6366f1;color:#fff;
    }
    .new-ws-btn.primary:hover{background:#818cf8}
    .new-ws-btn.primary:active{background:#4f46e5}

    /* ---------- tmux sessions sidebar section ---------- */
    .sidebar-section{padding:0 8px 6px}
    .sidebar-section h3{
      font-size:10px;font-weight:600;color:rgba(255,255,255,0.3);text-transform:uppercase;
      letter-spacing:.5px;padding:8px 4px 4px;
    }
    .tmux-item{
      padding:6px 10px;border-radius:6px;margin-bottom:2px;
      cursor:pointer;transition:background .12s;
      -webkit-tap-highlight-color:transparent;
    }
    .tmux-item:hover{background:rgba(255,255,255,0.04)}
    .tmux-item:active{background:rgba(255,255,255,0.07)}
    .tmux-name{
      font-size:11px;font-weight:600;color:#ccc;
      font-family:'SF Mono','Menlo','Consolas',monospace;
      display:block;
    }
    .tmux-meta{font-size:9px;color:rgba(255,255,255,0.3);display:block;margin-top:1px}

    /* ---------- collapsible sidebar sections ---------- */
    .sidebar-section-header{
      display:flex;justify-content:space-between;align-items:center;
      padding:6px 12px;cursor:pointer;
      font-size:10px;font-weight:600;color:rgba(255,255,255,0.4);
      text-transform:uppercase;letter-spacing:0.5px;user-select:none;
    }
    .sidebar-section-header:hover{color:rgba(255,255,255,0.6)}
    .sidebar-section-header .chevron{transition:transform 0.15s;font-size:10px}
    .sidebar-section-header.collapsed .chevron{transform:rotate(-90deg)}
    .sidebar-section-body{overflow:hidden}
    .sidebar-section-body.collapsed{display:none}
    #workspaces-section{flex:1;display:flex;flex-direction:column;min-height:0;overflow:hidden}

    /* ---------- Claude Code session items ---------- */
    .cc-item{
      padding:6px 12px;cursor:pointer;transition:background 0.1s;
      border-radius:6px;margin:1px 4px;
    }
    .cc-item:hover{background:rgba(99,102,241,0.1)}
    .cc-name{font-size:12px;font-weight:500;color:rgba(255,255,255,0.8)}
    .cc-meta{font-size:10px;color:rgba(255,255,255,0.3);margin-top:1px}

    /* sidebar settings footer */
    .sidebar-settings-footer{
      padding:6px 8px 8px;border-top:1px solid rgba(255,255,255,0.06);
      display:flex;align-items:center;justify-content:flex-end;
    }
    .settings-gear-btn{
      background:none;border:none;color:rgba(255,255,255,0.3);font-size:14px;
      cursor:pointer;width:28px;height:28px;border-radius:6px;
      display:flex;align-items:center;justify-content:center;
      transition:background .12s,color .12s;
    }
    .settings-gear-btn:hover{background:rgba(255,255,255,0.08);color:#fff}

    /* ---------- main area ---------- */
    #main{flex:1;display:flex;flex-direction:column;min-width:0}

    /* ---------- toolbar ---------- */
    #toolbar{
      display:flex;align-items:center;gap:0;
      height:38px;min-height:38px;
      background:rgba(20,20,38,0.92);
      backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);
      border-bottom:1px solid rgba(255,255,255,0.06);
      padding:0 8px;
    }
    #toggle-sidebar{
      display:none;background:none;border:none;color:#e0e0e0;
      font-size:16px;cursor:pointer;width:32px;height:32px;
      border-radius:6px;text-align:center;line-height:32px;flex-shrink:0;
    }
    #toggle-sidebar:hover{background:rgba(255,255,255,0.08)}

    /* ---------- tab bar ---------- */
    #tab-bar{display:flex;gap:1px;flex:1;overflow-x:auto;padding:0 4px;align-items:stretch;height:100%}
    #tab-bar::-webkit-scrollbar{display:none}
    .term-tab{
      display:flex;align-items:center;gap:5px;
      padding:0 10px;border:none;
      background:transparent;color:rgba(255,255,255,0.45);font-size:12px;font-weight:500;
      cursor:pointer;white-space:nowrap;height:100%;
      transition:background .1s,color .1s;
      -webkit-tap-highlight-color:transparent;
      position:relative;
    }
    .term-tab:hover{background:rgba(255,255,255,0.04);color:rgba(255,255,255,0.7)}
    .term-tab.active{color:#fff}
    .term-tab.active::after{
      content:'';position:absolute;bottom:0;left:8px;right:8px;
      height:2px;background:#6366f1;border-radius:1px 1px 0 0;
    }
    .term-tab .tab-close{
      width:16px;height:16px;line-height:16px;text-align:center;
      border-radius:3px;font-size:11px;color:rgba(255,255,255,0.3);
      opacity:0;transition:opacity .1s,background .1s,color .1s;
    }
    .term-tab:hover .tab-close{opacity:1}
    .term-tab .tab-close:hover{background:rgba(255,255,255,0.1);color:#fff}
    .term-tab .tab-tmux{
      font-size:8px;font-weight:700;padding:1px 4px;border-radius:3px;
      background:rgba(99,102,241,0.3);color:#a5b4fc;
      text-transform:uppercase;letter-spacing:.3px;
    }

    /* ---------- toolbar right section (bell, status) ---------- */
    .toolbar-right{
      display:flex;align-items:center;gap:6px;flex-shrink:0;margin-left:8px;
    }
    /* notification bell */
    .notif-bell-btn{
      position:relative;background:none;border:none;
      color:rgba(255,255,255,0.45);font-size:15px;cursor:pointer;
      width:30px;height:30px;border-radius:6px;
      display:flex;align-items:center;justify-content:center;
      transition:background .12s,color .12s;
    }
    .notif-bell-btn:hover{background:rgba(255,255,255,0.08);color:#fff}
    .notif-bell-btn .notif-count{
      position:absolute;top:2px;right:2px;
      background:#ef4444;color:#fff;font-size:8px;font-weight:700;
      width:14px;height:14px;border-radius:50%;
      display:flex;align-items:center;justify-content:center;
      line-height:1;
    }
    /* notification dropdown */
    .notif-dropdown{
      display:none;position:absolute;top:38px;right:8px;
      width:320px;max-height:400px;overflow-y:auto;
      background:rgba(28,28,50,0.96);
      backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);
      border:1px solid rgba(255,255,255,0.08);
      border-radius:10px;box-shadow:0 8px 32px rgba(0,0,0,0.5);
      z-index:150;
    }
    .notif-dropdown.open{display:block}
    .notif-dropdown-header{
      display:flex;align-items:center;justify-content:space-between;
      padding:10px 12px;border-bottom:1px solid rgba(255,255,255,0.06);
    }
    .notif-dropdown-header h3{font-size:13px;font-weight:600;color:#fff}
    .notif-mark-read{
      background:none;border:none;color:#6366f1;font-size:11px;
      cursor:pointer;font-weight:500;
    }
    .notif-mark-read:hover{color:#818cf8}
    .notif-item{
      padding:10px 12px;border-bottom:1px solid rgba(255,255,255,0.04);
      cursor:pointer;transition:background .1s;
    }
    .notif-item:hover{background:rgba(255,255,255,0.03)}
    .notif-item.unread{border-left:2px solid #6366f1}
    .notif-item .notif-title{font-size:12px;font-weight:600;color:#e0e0e0}
    .notif-item .notif-body{font-size:11px;color:rgba(255,255,255,0.45);margin-top:2px;line-height:1.3}
    .notif-item .notif-time{font-size:10px;color:rgba(255,255,255,0.25);margin-top:3px}
    .notif-empty{
      padding:24px;text-align:center;color:rgba(255,255,255,0.3);font-size:12px;
    }

    #status-indicator{
      display:flex;align-items:center;gap:5px;flex-shrink:0;
      font-size:10px;font-weight:500;color:rgba(255,255,255,0.35);
      transition:color .3s;
    }
    #status-indicator .status-dot{
      width:7px;height:7px;border-radius:50%;flex-shrink:0;
      background:rgba(255,255,255,0.2);transition:background .3s,box-shadow .3s;
    }
    #status-indicator.connected .status-dot{background:#4ade80;box-shadow:0 0 6px rgba(74,222,128,.5)}
    #status-indicator.connected{color:rgba(255,255,255,0.5)}
    #status-indicator.disconnected .status-dot{background:#ef4444;box-shadow:0 0 6px rgba(239,68,68,.4)}
    #status-indicator.disconnected{color:rgba(255,255,255,0.45)}

    /* ---------- terminal container ---------- */
    #terminal-container{flex:1;position:relative;overflow:hidden}
    .terminal-pane{
      position:absolute;top:0;left:0;right:0;bottom:0;
      display:none;
    }
    .terminal-pane.active{display:block}
    .terminal-pane .xterm{height:100%!important;width:100%!important}

    /* ---------- split view ---------- */
    .split-container{
      position:absolute;top:0;left:0;right:0;bottom:0;
      display:none;
    }
    .split-container.active{display:flex}
    .split-pane{
      flex:1;position:relative;overflow:hidden;min-width:80px;
    }
    .split-pane .xterm{height:100%!important;width:100%!important}
    .split-divider{
      width:4px;background:rgba(255,255,255,0.06);cursor:col-resize;
      flex-shrink:0;transition:background .15s;position:relative;
    }
    .split-divider:hover,
    .split-divider.dragging{background:rgba(99,102,241,0.5)}
    .split-divider::after{
      content:'';position:absolute;top:50%;left:-4px;right:-4px;
      height:32px;transform:translateY(-50%);
    }
    /* split tab bar (mini tab bar inside split panes) */
    .split-tab-bar{
      display:flex;align-items:stretch;height:26px;
      background:rgba(20,20,38,0.6);border-bottom:1px solid rgba(255,255,255,0.06);
    }
    .split-tab{
      display:flex;align-items:center;gap:4px;padding:0 8px;
      font-size:10px;font-weight:500;color:rgba(255,255,255,0.4);
      cursor:pointer;border:none;background:none;position:relative;
    }
    .split-tab.active{color:#fff}
    .split-tab.active::after{
      content:'';position:absolute;bottom:0;left:4px;right:4px;
      height:1.5px;background:#6366f1;border-radius:1px;
    }
    /* zoom button in split pane */
    .split-zoom-btn{
      position:absolute;top:4px;right:4px;z-index:5;
      background:rgba(0,0,0,0.5);border:1px solid rgba(255,255,255,0.1);
      color:rgba(255,255,255,0.5);font-size:11px;
      width:22px;height:22px;border-radius:4px;cursor:pointer;
      display:flex;align-items:center;justify-content:center;
      opacity:0;transition:opacity .15s,background .12s,color .12s;
    }
    .split-pane:hover .split-zoom-btn{opacity:1}
    .split-zoom-btn:hover{background:rgba(99,102,241,0.4);color:#fff;border-color:rgba(99,102,241,0.5)}
    /* zoomed state */
    .split-container.zoomed .split-pane{display:none}
    .split-container.zoomed .split-pane.zoomed-pane{display:block;flex:1}
    .split-container.zoomed .split-divider{display:none}
    .zoom-exit-bar{
      display:none;position:absolute;top:6px;right:6px;z-index:20;
      align-items:center;gap:6px;
      padding:3px 10px;border-radius:6px;
      background:rgba(0,0,0,0.6);backdrop-filter:blur(8px);
      font-size:10px;color:rgba(255,255,255,0.5);
    }
    .split-container.zoomed .zoom-exit-bar{display:flex}
    .zoom-exit-btn{
      background:rgba(99,102,241,0.3);border:none;color:#c7d2fe;
      padding:2px 8px;border-radius:4px;font-size:10px;cursor:pointer;
      transition:background .1s;
    }
    .zoom-exit-btn:hover{background:rgba(99,102,241,0.5);color:#fff}

    /* ---------- recursive layout splits ---------- */
    .layout-container{
      position:absolute;top:0;left:0;right:0;bottom:0;
      display:none;
    }
    .layout-container.active{display:flex}
    .layout-split{
      display:flex;
      width:100%;
      height:100%;
    }
    .layout-pane{
      display:flex;
      flex-direction:column;
      overflow:hidden;
      min-width:0;
      min-height:0;
    }
    .layout-pane .xterm{flex:1}
    .layout-pane .xterm-viewport,
    .layout-pane .xterm-screen{width:100%!important;height:100%!important}
    .layout-divider.v{
      width:4px;
      min-width:4px;
      background:rgba(255,255,255,0.06);
      cursor:col-resize;
      flex-shrink:0;
      transition:background .15s;
    }
    .layout-divider.h{
      height:4px;
      min-height:4px;
      background:rgba(255,255,255,0.06);
      cursor:row-resize;
      flex-shrink:0;
      transition:background .15s;
    }
    .layout-divider.v:hover,
    .layout-divider.h:hover{background:rgba(99,102,241,0.5)}

    /* empty state when no terminal is open */
    #empty-state{
      display:flex;align-items:center;justify-content:center;
      height:100%;color:rgba(255,255,255,0.3);font-size:14px;text-align:center;padding:20px;
      flex-direction:column;gap:12px;
    }
    #empty-state .hint{font-size:12px;color:rgba(255,255,255,0.2)}

    /* ---------- settings overlay ---------- */
    #settings-overlay{
      display:none;position:fixed;top:0;left:0;right:0;bottom:0;
      background:rgba(0,0,0,.6);z-index:200;
      align-items:center;justify-content:center;
    }
    #settings-overlay.open{display:flex}
    .settings-panel{
      background:rgba(28,28,50,0.96);
      backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);
      border-radius:14px;padding:20px;
      width:300px;max-width:90vw;box-shadow:0 12px 40px rgba(0,0,0,.5);
      border:1px solid rgba(255,255,255,0.08);
    }
    .settings-panel h2{
      font-size:15px;font-weight:700;color:#fff;margin-bottom:14px;
      display:flex;align-items:center;justify-content:space-between;
    }
    .settings-panel .settings-close{
      background:none;border:none;color:#888;font-size:16px;
      cursor:pointer;width:24px;height:24px;border-radius:6px;
      line-height:24px;text-align:center;
    }
    .settings-panel .settings-close:hover{background:rgba(255,255,255,0.08);color:#fff}
    .settings-row{
      display:flex;justify-content:space-between;align-items:center;
      padding:7px 0;border-bottom:1px solid rgba(255,255,255,.04);
      font-size:12px;
    }
    .settings-row .settings-label{color:rgba(255,255,255,0.4)}
    .settings-row .settings-value{color:#e0e0e0;font-weight:500}
    .settings-disconnect{
      width:100%;padding:9px;border:none;border-radius:8px;
      background:#ef4444;color:#fff;font-size:12px;font-weight:600;
      cursor:pointer;margin-top:14px;min-height:36px;transition:background .12s;
    }
    .settings-disconnect:hover{background:#dc2626}
    .settings-disconnect:active{background:#b91c1c}

    /* reconnecting overlay */
    .reconnect-overlay{
      position:absolute;top:0;left:0;right:0;bottom:0;
      background:rgba(26,26,46,.9);
      display:flex;align-items:center;justify-content:center;
      flex-direction:column;gap:8px;z-index:10;
      color:rgba(255,255,255,0.4);font-size:13px;
    }
    .reconnect-overlay .spinner{
      width:20px;height:20px;border:2px solid rgba(255,255,255,0.1);border-top-color:#6366f1;
      border-radius:50%;animation:spin .7s linear infinite;
    }
    @keyframes spin{to{transform:rotate(360deg)}}

    /* animation */
    @keyframes fadeIn{from{opacity:0;transform:translateY(2px)}to{opacity:1;transform:translateY(0)}}
    .ws-row{animation:fadeIn .15s ease-out}

    /* ---------- mobile responsive ---------- */
    @media(max-width:767px){
      #sidebar{
        position:fixed;top:0;left:0;bottom:0;
        transform:translateX(-100%);
        box-shadow:4px 0 24px rgba(0,0,0,.5);
        width:280px;min-width:280px;
      }
      #sidebar.open{transform:translateX(0)}
      #close-sidebar{display:block}
      #toggle-sidebar{display:block}
      #sidebar-backdrop{
        display:none;position:fixed;top:0;left:0;right:0;bottom:0;
        background:rgba(0,0,0,.5);z-index:99;
      }
      #sidebar-backdrop.visible{display:block}
      #terminal-container{position:absolute;top:0;left:0;right:0;bottom:0}
      .terminal-pane{padding:0!important;margin:0!important}
      .notif-dropdown{width:calc(100vw - 16px);right:0}
    }

    /* touch: make everything 44px minimum */
    @media(pointer:coarse){
      .ws-row{min-height:44px;padding:10px 10px 10px 0}
      .term-tab{padding:0 12px}
    }
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
        <div class="sidebar-section" id="workspaces-section">
          <div class="sidebar-section-header" onclick="app.toggleSection('workspaces')">
            Workspaces <span class="chevron">&#9660;</span>
          </div>
          <div class="sidebar-section-body" id="workspace-list" style="flex:1;overflow-y:auto;padding:6px 8px;-webkit-overflow-scrolling:touch"></div>
        </div>
        <div class="sidebar-section" id="tmux-section" style="display:none">
          <div class="sidebar-section-header" onclick="app.toggleSection('tmux')">
            Tmux Sessions <span class="chevron">&#9660;</span>
            <button onclick="event.stopPropagation();app.killAllTmuxSessions()" style="font-size:9px;background:rgba(239,68,68,0.15);color:#f87171;border:1px solid rgba(239,68,68,0.2);padding:2px 6px;border-radius:4px;cursor:pointer;margin-left:auto" title="Kill all tmux sessions">Kill All</button>
          </div>
          <div class="sidebar-section-body" id="tmux-sessions"></div>
        </div>
        <div class="sidebar-section" id="cc-section" style="display:none">
          <div class="sidebar-section-header" onclick="app.toggleSection('cc')">
            Claude Code Sessions <span class="chevron">&#9660;</span>
          </div>
          <div class="sidebar-section-body" id="cc-sessions"></div>
        </div>
        <div class="sidebar-footer">
          <div class="new-ws-btn-group">
            <button class="new-ws-btn primary" onclick="app.openDefaultTerminal()">+ New Workspace</button>
            <button class="new-ws-btn" onclick="app.openNewTmuxWorkspace()">+ Tmux</button>
          </div>
        </div>
        <div class="sidebar-settings-footer">
          <button class="settings-gear-btn" onclick="app.openSettings()" title="Settings">&#9881;</button>
        </div>
      </aside>
      <main id="main">
        <div id="toolbar">
          <button id="toggle-sidebar" onclick="app.toggleSidebar()">&#9776;</button>
          <div id="tab-bar"></div>
          <div class="toolbar-right">
            <button class="notif-bell-btn" onclick="app.toggleNotifications(event)">
              &#128276;
              <span class="notif-count" id="notif-badge" style="display:none">0</span>
            </button>
            <div id="status-indicator"><span class="status-dot"></span><span class="status-text">Connecting...</span></div>
          </div>
        </div>
        <div class="notif-dropdown" id="notif-dropdown">
          <div class="notif-dropdown-header">
            <h3>Notifications</h3>
            <button class="notif-mark-read" onclick="app.markAllRead()">Mark all read</button>
          </div>
          <div id="notif-list"></div>
        </div>
        <div id="terminal-container">
          <div id="empty-state">
            <div>Select a workspace to open a terminal</div>
            <div class="hint">or press "+ New Workspace"</div>
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
        this.sessionId = null;
        this.reconnectDelay = 1000;
        this.reconnectTimer = null;
        this.closed = false;
        this.isSplitChild = false;

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
        var self = this;
        requestAnimationFrame(function(){ self.fitAddon.fit(); });
        this.connect();
    };

    TerminalTab.prototype.openInElement = function(el) {
        this.terminal.open(el);
        var self = this;
        requestAnimationFrame(function(){ self.fitAddon.fit(); });
        this.connect();
    };

    TerminalTab.prototype.connect = function() {
        var self = this;
        var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        this.ws = new WebSocket(proto + '//' + location.host + '/ws/terminal');

        this.ws.onopen = function() {
            self.reconnectDelay = 1000;
            self.hideReconnectOverlay();
            if (self.sessionId) {
                self.ws.send(JSON.stringify({ type: 'reconnect', sessionId: self.sessionId }));
            } else {
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
                    if (self.ws && self.ws.readyState === WebSocket.OPEN) {
                        self.ws.send(JSON.stringify({ type: 'pong' }));
                    }
                    return;
                }
            } catch(ignored) {}
            self.terminal.write(e.data);
        };

        this.ws.onclose = function() {
            if (self.closed) return;
            self.showReconnectOverlay();
            self.scheduleReconnect();
        };

        this.ws.onerror = function() {};

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
        self.reconnectDelay = Math.min(self.reconnectDelay * 2, 10000);
    };

    TerminalTab.prototype.showReconnectOverlay = function() {
        var container = this.isSplitChild ? this.containerEl.parentNode : this.containerEl;
        if (!container) return;
        if (container.querySelector('.reconnect-overlay')) return;
        var overlay = document.createElement('div');
        overlay.className = 'reconnect-overlay';
        overlay.innerHTML = '<div class="spinner"></div><div>Reconnecting...</div>';
        container.appendChild(overlay);
    };

    TerminalTab.prototype.hideReconnectOverlay = function() {
        var container = this.isSplitChild ? this.containerEl.parentNode : this.containerEl;
        if (!container) return;
        var overlay = container.querySelector('.reconnect-overlay');
        if (overlay) overlay.parentNode.removeChild(overlay);
    };

    TerminalTab.prototype.fit = function() {
        try { this.fitAddon.fit(); } catch(e) {}
    };

    TerminalTab.prototype.show = function() {
        if (!this.isSplitChild) {
            this.containerEl.classList.add('active');
        }
        var self = this;
        requestAnimationFrame(function(){
            self.fit();
            self.terminal.focus();
        });
    };

    TerminalTab.prototype.hide = function() {
        if (!this.isSplitChild) {
            this.containerEl.classList.remove('active');
        }
    };

    TerminalTab.prototype.close = function() {
        this.closed = true;
        if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
        if (this.ws) { this.ws.close(); this.ws = null; }
        this.terminal.dispose();
        if (!this.isSplitChild && this.containerEl.parentNode) {
            this.containerEl.parentNode.removeChild(this.containerEl);
        }
    };

    /* ============================================================
       SplitView -- manages two TerminalTabs side-by-side
       ============================================================ */
    function SplitView(id, tabs) {
        this.id = id;
        this.tabs = tabs || [];
        this.zoomedIndex = -1;
        this.splitRatio = 0.5;
        this._dragging = false;

        this.containerEl = document.createElement('div');
        this.containerEl.className = 'split-container';
        this.containerEl.id = 'split-' + id;
    }

    SplitView.prototype.render = function(parentEl) {
        var self = this;
        this.containerEl.innerHTML = '';

        // Zoom exit bar
        var zoomBar = document.createElement('div');
        zoomBar.className = 'zoom-exit-bar';
        zoomBar.innerHTML = '<span>ZOOMED</span><button class="zoom-exit-btn" onclick="app.exitZoom()">Exit Zoom</button>';
        this.containerEl.appendChild(zoomBar);

        for (var i = 0; i < this.tabs.length; i++) {
            var pane = document.createElement('div');
            pane.className = 'split-pane';
            pane.setAttribute('data-pane-idx', String(i));
            if (i === 0) {
                pane.style.flex = '0 0 ' + (this.splitRatio * 100) + '%';
            }

            // Zoom button
            var zoomBtn = document.createElement('button');
            zoomBtn.className = 'split-zoom-btn';
            zoomBtn.innerHTML = '&#x26F6;';
            zoomBtn.setAttribute('data-zoom-idx', String(i));
            zoomBtn.addEventListener('click', (function(idx) {
                return function(e) {
                    e.stopPropagation();
                    self.zoom(idx);
                };
            })(i));
            pane.appendChild(zoomBtn);

            // Terminal element
            var termEl = document.createElement('div');
            termEl.style.cssText = 'position:absolute;top:0;left:0;right:0;bottom:0';
            pane.appendChild(termEl);

            this.tabs[i].isSplitChild = true;
            this.tabs[i].containerEl = termEl;
            this.containerEl.appendChild(pane);

            // Add divider between panes
            if (i < this.tabs.length - 1) {
                var divider = document.createElement('div');
                divider.className = 'split-divider';
                this.containerEl.appendChild(divider);
                this._setupDividerDrag(divider, pane);
            }
        }

        parentEl.appendChild(this.containerEl);

        // Open terminals
        for (var j = 0; j < this.tabs.length; j++) {
            this.tabs[j].openInElement(this.tabs[j].containerEl);
        }
    };

    SplitView.prototype._setupDividerDrag = function(divider, leftPane) {
        var self = this;
        var startX = 0;
        var startWidth = 0;
        var containerWidth = 0;

        function onMouseDown(e) {
            e.preventDefault();
            self._dragging = true;
            divider.classList.add('dragging');
            startX = e.clientX || (e.touches ? e.touches[0].clientX : 0);
            startWidth = leftPane.offsetWidth;
            containerWidth = self.containerEl.offsetWidth;
            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
            document.addEventListener('touchmove', onMouseMove, {passive: false});
            document.addEventListener('touchend', onMouseUp);
        }

        function onMouseMove(e) {
            if (!self._dragging) return;
            e.preventDefault();
            var clientX = e.clientX || (e.touches ? e.touches[0].clientX : 0);
            var dx = clientX - startX;
            var newWidth = startWidth + dx;
            var ratio = newWidth / containerWidth;
            if (ratio < 0.15) ratio = 0.15;
            if (ratio > 0.85) ratio = 0.85;
            self.splitRatio = ratio;
            leftPane.style.flex = '0 0 ' + (ratio * 100) + '%';
            self.fitAll();
        }

        function onMouseUp() {
            self._dragging = false;
            divider.classList.remove('dragging');
            document.removeEventListener('mousemove', onMouseMove);
            document.removeEventListener('mouseup', onMouseUp);
            document.removeEventListener('touchmove', onMouseMove);
            document.removeEventListener('touchend', onMouseUp);
            self.fitAll();
        }

        divider.addEventListener('mousedown', onMouseDown);
        divider.addEventListener('touchstart', onMouseDown, {passive: false});
    };

    SplitView.prototype.zoom = function(idx) {
        this.zoomedIndex = idx;
        this.containerEl.classList.add('zoomed');
        var panes = this.containerEl.querySelectorAll('.split-pane');
        for (var i = 0; i < panes.length; i++) {
            panes[i].classList.remove('zoomed-pane');
        }
        if (panes[idx]) {
            panes[idx].classList.add('zoomed-pane');
            // Force the zoomed pane to fill the container
            panes[idx].style.width = '100%';
            panes[idx].style.height = '100%';
            panes[idx].style.flex = '1 1 100%';
        }
        // Only fit the zoomed terminal after layout settles
        var self = this;
        requestAnimationFrame(function() {
            if (self.tabs[idx]) {
                self.tabs[idx].fit();
                self.tabs[idx].terminal.focus();
            }
        });
    };

    SplitView.prototype.unzoom = function() {
        var prevIdx = this.zoomedIndex;
        this.zoomedIndex = -1;
        this.containerEl.classList.remove('zoomed');
        var panes = this.containerEl.querySelectorAll('.split-pane');
        for (var i = 0; i < panes.length; i++) {
            panes[i].classList.remove('zoomed-pane');
            // Restore original sizing
            panes[i].style.width = '';
            panes[i].style.height = '';
            if (i === 0) {
                panes[i].style.flex = '0 0 ' + (this.splitRatio * 100) + '%';
            } else {
                panes[i].style.flex = '';
            }
        }
        // Refit all terminals after layout settles
        var self = this;
        requestAnimationFrame(function() {
            self.fitAll();
        });
    };

    SplitView.prototype.show = function() {
        this.containerEl.classList.add('active');
        this.fitAll();
    };

    SplitView.prototype.hide = function() {
        this.containerEl.classList.remove('active');
    };

    SplitView.prototype.fitAll = function() {
        for (var i = 0; i < this.tabs.length; i++) {
            this.tabs[i].fit();
        }
    };

    SplitView.prototype.close = function() {
        for (var i = 0; i < this.tabs.length; i++) {
            this.tabs[i].close();
        }
        if (this.containerEl.parentNode) {
            this.containerEl.parentNode.removeChild(this.containerEl);
        }
    };

    SplitView.prototype.focusFirst = function() {
        if (this.tabs.length > 0) {
            this.tabs[0].terminal.focus();
        }
    };

    /* ============================================================
       LayoutView -- recursive split layout from API layout tree
       ============================================================ */
    function buildLayoutNode(node, panels, parentEl) {
        if (!node) return null;

        if (node.type === 'pane') {
            var panelId = (node.pane && node.pane.panelIds && node.pane.panelIds.length > 0) ? node.pane.panelIds[0] : null;
            if (!panelId) return null;
            var panel = null;
            for (var pi = 0; pi < panels.length; pi++) {
                if (panels[pi].id === panelId) { panel = panels[pi]; break; }
            }
            if (!panel || !panel.tmuxSession) return null;

            var tab = new TerminalTab(panel.id, panel.directory || '~', panel.tmuxSession, panel.tmuxSession);
            tab.isSplitChild = true;
            var pane = document.createElement('div');
            pane.className = 'layout-pane';
            pane.style.flex = '1';
            parentEl.appendChild(pane);
            tab.containerEl = pane;
            tab.openInElement(pane);
            return { tab: tab, el: pane };
        }

        if (node.type === 'split') {
            var split = node.split;
            if (!split) return null;
            var container = document.createElement('div');
            container.className = 'layout-split';
            container.style.display = 'flex';
            container.style.flexDirection = split.orientation === 'vertical' ? 'column' : 'row';
            container.style.flex = '1';
            container.style.height = '100%';
            parentEl.appendChild(container);

            // First child wrapper
            var divPos = (typeof split.dividerPosition === 'number') ? split.dividerPosition : 0.5;
            var firstEl = document.createElement('div');
            firstEl.style.flex = '0 0 ' + (divPos * 100) + '%';
            firstEl.style.display = 'flex';
            firstEl.style.overflow = 'hidden';
            container.appendChild(firstEl);
            var first = buildLayoutNode(split.first, panels, firstEl);

            // Divider
            var divider = document.createElement('div');
            divider.className = 'layout-divider ' + (split.orientation === 'vertical' ? 'h' : 'v');
            container.appendChild(divider);

            // Second child wrapper
            var secondEl = document.createElement('div');
            secondEl.style.flex = '1';
            secondEl.style.display = 'flex';
            secondEl.style.overflow = 'hidden';
            container.appendChild(secondEl);
            var second = buildLayoutNode(split.second, panels, secondEl);

            return { first: first, second: second, el: container, divider: divider, firstEl: firstEl, secondEl: secondEl, orientation: split.orientation };
        }

        return null;
    }

    function collectLayoutTabs(layoutResult) {
        var tabs = [];
        if (!layoutResult) return tabs;
        if (layoutResult.tab) {
            tabs.push(layoutResult.tab);
        }
        if (layoutResult.first) {
            tabs = tabs.concat(collectLayoutTabs(layoutResult.first));
        }
        if (layoutResult.second) {
            tabs = tabs.concat(collectLayoutTabs(layoutResult.second));
        }
        return tabs;
    }

    function LayoutView(wsId, layoutTree, panels) {
        this.id = wsId;
        this.tabs = [];
        this.layoutTree = layoutTree;
        this.panels = panels;

        this.containerEl = document.createElement('div');
        this.containerEl.className = 'layout-container';
        this.containerEl.id = 'layout-' + wsId;
    }

    LayoutView.prototype.render = function(parentEl) {
        this.containerEl.innerHTML = '';
        parentEl.appendChild(this.containerEl);
        var result = buildLayoutNode(this.layoutTree, this.panels, this.containerEl);
        this.tabs = collectLayoutTabs(result);
        this._layoutResult = result;

        // Fit all terminals after DOM settles
        var self = this;
        requestAnimationFrame(function() {
            self.fitAll();
        });
    };

    LayoutView.prototype.show = function() {
        this.containerEl.classList.add('active');
        this.fitAll();
    };

    LayoutView.prototype.hide = function() {
        this.containerEl.classList.remove('active');
    };

    LayoutView.prototype.fitAll = function() {
        for (var i = 0; i < this.tabs.length; i++) {
            this.tabs[i].fit();
        }
    };

    LayoutView.prototype.close = function() {
        for (var i = 0; i < this.tabs.length; i++) {
            this.tabs[i].close();
        }
        if (this.containerEl.parentNode) {
            this.containerEl.parentNode.removeChild(this.containerEl);
        }
    };

    LayoutView.prototype.focusFirst = function() {
        if (this.tabs.length > 0) {
            this.tabs[0].terminal.focus();
        }
    };

    /* ============================================================
       App  -- manages tabs, sidebar, state WebSocket, notifications
       ============================================================ */
    function App() {
        this.tabs = [];
        this.splitViews = [];
        this.activeTab = null;
        this.activeSplit = null;
        this.stateWs = null;
        this.workspaces = [];
        this.notifications = [];
        this.reconnectDelay = 1000;
        this._tmuxSessionData = [];
        this._lastStateJson = '';
        this._lastWorkspacesHtml = '';
        this._lastTmuxHtml = '';
        this._lastTabsHtml = '';
        this._lastCCHtml = '';
        this.ccSessions = [];
        this._notifOpen = false;
    }

    App.prototype.init = function() {
        this.connectState();
        this.fetchWorkspaces();
        this.fetchNotifications();
        this.fetchCCSessions();
        var self = this;
        window.addEventListener('resize', function() {
            if (self.activeSplit) {
                self.activeSplit.fitAll();
            } else if (self.activeTab) {
                self.activeTab.fit();
            }
        });
        // Close notification dropdown on outside click
        document.addEventListener('click', function(e) {
            if (!self._notifOpen) return;
            var dropdown = document.getElementById('notif-dropdown');
            var bell = document.querySelector('.notif-bell-btn');
            // Walk up from target to see if we clicked inside dropdown or bell
            var node = e.target;
            while (node) {
                if (node === dropdown || node === bell) return;
                node = node.parentNode;
            }
            self.closeNotifications();
        });
    };

    /* ---- state WebSocket ---- */
    App.prototype.connectState = function() {
        var self = this;
        var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        this.stateWs = new WebSocket(proto + '//' + location.host + '/ws');

        this.stateWs.onopen = function() {
            var el = document.getElementById('status-indicator');
            el.className = 'connected';
            var txt = el.querySelector('.status-text');
            if (txt) txt.textContent = 'Connected';
            self.reconnectDelay = 1000;
        };
        this.stateWs.onclose = function() {
            var el = document.getElementById('status-indicator');
            el.className = 'disconnected';
            var txt = el.querySelector('.status-text');
            if (txt) txt.textContent = 'Disconnected';
            setTimeout(function(){ self.connectState(); }, self.reconnectDelay);
            self.reconnectDelay = Math.min(self.reconnectDelay * 1.5, 15000);
        };
        this.stateWs.onerror = function(){};
        this.stateWs.onmessage = function(e) {
            try {
                var msg = JSON.parse(e.data);
                if (msg.type === 'ping') {
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
                    if (msg.tmuxSessions) {
                        self.renderTmuxSessions(msg.tmuxSessions);
                    }
                }
                if (msg.type === 'notification') {
                    self.notifications.unshift(msg);
                    self.updateNotifBadge();
                    self.renderNotifications();
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

    App.prototype.fetchNotifications = function() {
        var self = this;
        fetch('/api/notifications').then(function(r){ return r.json(); }).then(function(data){
            self.notifications = data || [];
            self.updateNotifBadge();
            self.renderNotifications();
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

    /* ---- notifications ---- */
    App.prototype.toggleNotifications = function(e) {
        if (e) e.stopPropagation();
        var dropdown = document.getElementById('notif-dropdown');
        this._notifOpen = !this._notifOpen;
        if (this._notifOpen) {
            dropdown.classList.add('open');
            this.fetchNotifications();
        } else {
            dropdown.classList.remove('open');
        }
    };

    App.prototype.closeNotifications = function() {
        this._notifOpen = false;
        document.getElementById('notif-dropdown').classList.remove('open');
    };

    App.prototype.updateNotifBadge = function() {
        var unread = 0;
        for (var i = 0; i < this.notifications.length; i++) {
            if (!this.notifications[i].isRead) unread++;
        }
        var badge = document.getElementById('notif-badge');
        if (unread > 0) {
            badge.textContent = unread > 99 ? '99+' : String(unread);
            badge.style.display = '';
        } else {
            badge.style.display = 'none';
        }
    };

    App.prototype.renderNotifications = function() {
        var el = document.getElementById('notif-list');
        if (!this.notifications || !this.notifications.length) {
            el.innerHTML = '<div class="notif-empty">No notifications</div>';
            return;
        }
        var html = '';
        var now = Date.now();
        for (var i = 0; i < Math.min(this.notifications.length, 30); i++) {
            var n = this.notifications[i];
            var unreadCls = n.isRead ? '' : ' unread';
            var timeStr = '';
            if (n.createdAt) {
                var diff = now - new Date(n.createdAt).getTime();
                if (diff < 60000) timeStr = 'just now';
                else if (diff < 3600000) timeStr = Math.floor(diff / 60000) + 'm ago';
                else if (diff < 86400000) timeStr = Math.floor(diff / 3600000) + 'h ago';
                else timeStr = Math.floor(diff / 86400000) + 'd ago';
            }
            html += '<div class="notif-item' + unreadCls + '" data-notif-id="' + esc(n.id || '') + '">'
                + '<div class="notif-title">' + esc(n.title || 'Notification') + '</div>'
                + (n.body ? '<div class="notif-body">' + esc(n.body) + '</div>' : '')
                + (timeStr ? '<div class="notif-time">' + timeStr + '</div>' : '')
                + '</div>';
        }
        el.innerHTML = html;
    };

    App.prototype.markAllRead = function() {
        for (var i = 0; i < this.notifications.length; i++) {
            this.notifications[i].isRead = true;
        }
        this.updateNotifBadge();
        this.renderNotifications();
    };

    /* ---- workspaces rendering (native-matching compact rows) ---- */
    App.prototype.renderWorkspaces = function() {
        var el = document.getElementById('workspace-list');
        if (!this.workspaces.length) {
            var emptyHtml = '<div style="text-align:center;color:rgba(255,255,255,0.25);padding:30px 10px;font-size:12px">No workspaces open</div>';
            if (emptyHtml !== this._lastWorkspacesHtml) {
                this._lastWorkspacesHtml = emptyHtml;
                el.innerHTML = emptyHtml;
            }
            return;
        }
        var self = this;
        var newHtml = this.workspaces.map(function(w) {
            var sel = w.isSelected ? ' selected' : '';
            var hasTab = self.tabs.some(function(t){ return t.workspaceId === w.id; });
            var hasSplit = self.splitViews.some(function(sv){ return sv.id === w.id; });

            // Shorten directory for display
            var dirDisplay = w.directory || '';
            var home = '/Users/';
            var homeIdx = dirDisplay.indexOf(home);
            if (homeIdx === 0) {
                var parts = dirDisplay.split('/');
                if (parts.length > 3) {
                    dirDisplay = '~/' + parts.slice(3).join('/');
                }
            }

            // Top line: badges + title + close
            var topLine = '';

            // Unread badge (leftmost, like native)
            if (w.unreadCount > 0) {
                topLine += '<span class="unread-badge">' + w.unreadCount + '</span>';
            }

            // Pin icon
            if (w.isPinned) {
                topLine += '<span class="pin-icon">&#128204;</span>';
            }

            // Tmux badge
            var tmuxPanels = (w.panels || []).filter(function(p){ return !!p.tmuxSession; });
            if (tmuxPanels.length > 0) {
                topLine += '<span class="tmux-badge">TMUX</span>';
            }

            // Color dot
            if (w.color) {
                topLine += '<span class="color-dot" style="background:' + esc(w.color) + '"></span>';
            }

            // Title
            topLine += '<span class="ws-title">' + esc(w.title) + '</span>';

            // Open dot
            if (hasTab || hasSplit) {
                topLine += '<span class="open-dot"></span>';
            }

            // Close button (shows on hover)
            topLine += '<button class="ws-close" data-close-ws="' + esc(w.id) + '" title="Close">&times;</button>';

            // Meta line: panel count
            var metaLine = '<span class="panel-count">' + w.panelCount + ' panel' + (w.panelCount !== 1 ? 's' : '') + '</span>';

            var firstTmux = tmuxPanels.length > 0 ? tmuxPanels[0] : null;
            var tmuxAttr = firstTmux ? ' data-tmux="' + esc(firstTmux.tmuxSession) + '"' : '';
            var panelCountAttr = ' data-panel-count="' + (tmuxPanels.length || w.panelCount) + '"';
            // Encode panel tmux sessions for split view
            var panelsJson = '';
            if (tmuxPanels.length > 1) {
                var pNames = [];
                for (var pi = 0; pi < tmuxPanels.length; pi++) {
                    pNames.push(tmuxPanels[pi].tmuxSession);
                }
                panelsJson = ' data-panels="' + esc(pNames.join(',')) + '"';
            }

            var rowHtml = '<div class="ws-row' + sel + '" data-id="' + esc(w.id) + '" data-dir="' + esc(w.directory) + '" data-title="' + esc(w.title) + '"' + tmuxAttr + panelCountAttr + panelsJson + '>'
                + '<div class="ws-left">'
                + '<div class="ws-top-line">' + topLine + '</div>'
                + '<div class="ws-dir">' + esc(dirDisplay) + '</div>'
                + '<div class="ws-meta-line">' + metaLine + '</div>'
                + '</div>'
                + '</div>';
            return rowHtml;
        }).join('');

        if (newHtml === this._lastWorkspacesHtml) { return; }
        this._lastWorkspacesHtml = newHtml;
        el.innerHTML = newHtml;

        // Click handlers for workspace rows
        el.querySelectorAll('.ws-row').forEach(function(row) {
            row.addEventListener('click', function(e) {
                // Check if close button was clicked
                var closeBtn = e.target;
                while (closeBtn && closeBtn !== row) {
                    if (closeBtn.hasAttribute && closeBtn.hasAttribute('data-close-ws')) {
                        e.stopPropagation();
                        // Close all tabs for this workspace
                        var wsId = closeBtn.getAttribute('data-close-ws');
                        self._closeWorkspaceTabs(wsId);
                        return;
                    }
                    closeBtn = closeBtn.parentNode;
                }

                var id = row.getAttribute('data-id');
                var dir = row.getAttribute('data-dir');
                var title = row.getAttribute('data-title');
                var tmux = row.getAttribute('data-tmux') || null;
                var panels = row.getAttribute('data-panels') || null;

                // Look up full workspace data for layout tree
                var wsData = null;
                for (var wi = 0; wi < self.workspaces.length; wi++) {
                    if (self.workspaces[wi].id === id) { wsData = self.workspaces[wi]; break; }
                }

                // If workspace has a layout tree, use recursive LayoutView
                if (wsData && wsData.layout && wsData.layout.type) {
                    self.openLayoutView(id, title, wsData.layout, wsData.panels || []);
                    return;
                }

                // Fallback: if workspace has multiple tmux panels but no layout, use flat SplitView
                if (panels) {
                    var panelNames = panels.split(',');
                    if (panelNames.length > 1) {
                        self.openSplitView(id, dir, title, panelNames);
                        return;
                    }
                }

                self.openTerminal({ id: id, directory: dir, title: title, tmuxSession: tmux });
            });
        });
    };

    App.prototype._closeWorkspaceTabs = function(wsId) {
        // Close any split views for this workspace
        var svCopy = this.splitViews.slice();
        for (var i = 0; i < svCopy.length; i++) {
            if (svCopy[i].id === wsId) {
                this.closeSplitView(svCopy[i]);
            }
        }
        // Close any tabs for this workspace
        var tabsCopy = this.tabs.slice();
        for (var j = 0; j < tabsCopy.length; j++) {
            if (tabsCopy[j].workspaceId === wsId) {
                this.closeTab(tabsCopy[j]);
            }
        }
    };

    /* ---- terminal tab management ---- */
    App.prototype.openTerminal = function(workspace) {
        // If a tab already exists for this workspace, just activate it.
        var existing = null;
        for (var i = 0; i < this.tabs.length; i++) {
            if (workspace.tmuxSession && this.tabs[i].tmuxSession === workspace.tmuxSession) {
                existing = this.tabs[i]; break;
            }
            if (this.tabs[i].workspaceId === workspace.id) { existing = this.tabs[i]; break; }
        }
        if (existing) {
            this.activateTab(existing);
            this.closeSidebarIfMobile();
            return;
        }

        // Check if there is a split view for this workspace
        for (var s = 0; s < this.splitViews.length; s++) {
            if (this.splitViews[s].id === workspace.id) {
                this.activateSplit(this.splitViews[s]);
                this.closeSidebarIfMobile();
                return;
            }
        }

        // Hide the empty state.
        var empty = document.getElementById('empty-state');
        if (empty) empty.style.display = 'none';

        var tab = new TerminalTab(workspace.id, workspace.directory, workspace.title, workspace.tmuxSession, workspace.panelLabel || null);
        this.tabs.push(tab);
        tab.open(document.getElementById('terminal-container'));
        this.activateTab(tab);
        this.renderTabs();
        this.renderWorkspaces();
        this.closeSidebarIfMobile();
    };

    /* ---- split view ---- */
    App.prototype.openSplitView = function(wsId, dir, title, tmuxNames) {
        // Check if split view already exists
        for (var i = 0; i < this.splitViews.length; i++) {
            if (this.splitViews[i].id === wsId) {
                this.activateSplit(this.splitViews[i]);
                this.closeSidebarIfMobile();
                return;
            }
        }

        var empty = document.getElementById('empty-state');
        if (empty) empty.style.display = 'none';

        var tabs = [];
        for (var j = 0; j < tmuxNames.length; j++) {
            var t = new TerminalTab(wsId, dir, title, tmuxNames[j], 'Panel ' + (j + 1));
            tabs.push(t);
        }

        var sv = new SplitView(wsId, tabs);
        this.splitViews.push(sv);
        sv.render(document.getElementById('terminal-container'));
        this.activateSplit(sv);
        this.renderTabs();
        this.renderWorkspaces();
        this.closeSidebarIfMobile();
    };

    /* ---- layout view (recursive split tree) ---- */
    App.prototype.openLayoutView = function(wsId, title, layoutTree, panels) {
        // Check if a layout/split view already exists for this workspace
        for (var i = 0; i < this.splitViews.length; i++) {
            if (this.splitViews[i].id === wsId) {
                this.activateSplit(this.splitViews[i]);
                this.closeSidebarIfMobile();
                return;
            }
        }

        var empty = document.getElementById('empty-state');
        if (empty) empty.style.display = 'none';

        var lv = new LayoutView(wsId, layoutTree, panels);
        this.splitViews.push(lv);
        lv.render(document.getElementById('terminal-container'));
        this.activateSplit(lv);
        this.renderTabs();
        this.renderWorkspaces();
        this.closeSidebarIfMobile();
    };

    App.prototype.activateSplit = function(sv) {
        // Hide all tabs and splits
        for (var i = 0; i < this.tabs.length; i++) this.tabs[i].hide();
        for (var j = 0; j < this.splitViews.length; j++) this.splitViews[j].hide();
        this.activeTab = null;
        this.activeSplit = sv;
        sv.show();
        sv.focusFirst();
        this.renderTabs();
    };

    App.prototype.closeSplitView = function(sv) {
        sv.close();
        this.splitViews = this.splitViews.filter(function(s){ return s !== sv; });
        if (this.activeSplit === sv) {
            this.activeSplit = null;
            // Activate last tab or last split
            if (this.splitViews.length > 0) {
                this.activateSplit(this.splitViews[this.splitViews.length - 1]);
            } else if (this.tabs.length > 0) {
                this.activateTab(this.tabs[this.tabs.length - 1]);
            }
        }
        this.renderTabs();
        this.renderWorkspaces();
        if (this.tabs.length === 0 && this.splitViews.length === 0) {
            var empty = document.getElementById('empty-state');
            if (empty) empty.style.display = '';
        }
    };

    App.prototype.exitZoom = function() {
        if (this.activeSplit) {
            this.activeSplit.unzoom();
        }
    };

    App.prototype.openDefaultTerminal = function() {
        var homeDir = '~';
        if (this.workspaces.length > 0) {
            var sel = this.workspaces.find(function(w){ return w.isSelected; });
            if (sel) {
                // Prefer layout tree if present
                if (sel.layout && sel.layout.type) {
                    this.openLayoutView(sel.id, sel.title, sel.layout, sel.panels || []);
                    return;
                }
                var tmuxPanels = (sel.panels || []).filter(function(p){ return !!p.tmuxSession; });
                if (tmuxPanels.length > 1) {
                    var pNames = [];
                    for (var k = 0; k < tmuxPanels.length; k++) {
                        pNames.push(tmuxPanels[k].tmuxSession);
                    }
                    this.openSplitView(sel.id, sel.directory, sel.title, pNames);
                    return;
                }
                this.openTerminal({ id: sel.id, directory: sel.directory, title: sel.title,
                    tmuxSession: tmuxPanels.length > 0 ? tmuxPanels[0].tmuxSession : null });
                return;
            }
        }
        var fakeId = 'home-' + Math.random().toString(36).substr(2,6);
        this.openTerminal({ id: fakeId, directory: homeDir, title: 'Terminal' });
    };

    App.prototype.openNewTmuxWorkspace = function() {
        // Create a new tmux workspace in the NATIVE APP, then attach to it from the browser.
        // Use the directory of the currently active tab or selected workspace.
        var self = this;
        var dir = null;
        if (self.activeTab) {
            dir = self.activeTab.directory;
        }
        if (!dir || dir === '~') {
            var sel = self.workspaces.find(function(w) { return w.isSelected; });
            if (sel) dir = sel.directory;
        }
        var body = { tmux: true };
        if (dir && dir !== '~') body.directory = dir;
        fetch('/api/workspaces/new', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        }).then(function(r) { return r.json(); }).then(function(data) {
            if (!data.ok) return;
            // The native app created a tmux workspace. Wait a moment for it to appear
            // in the workspace list, then attach to its tmux session.
            setTimeout(function() {
                self.fetchWorkspaces();
                // Also refresh tmux sessions to find the new one
                fetch('/api/tmux/sessions').then(function(r) { return r.json(); }).then(function(sessions) {
                    self._tmuxSessionData = sessions || [];
                    self.renderTmuxSessions(sessions);
                    // Find the newest unattached-by-browser session and attach
                    for (var i = 0; i < sessions.length; i++) {
                        var alreadyOpen = false;
                        for (var j = 0; j < self.tabs.length; j++) {
                            if (self.tabs[j].tmuxSession === sessions[i].name) {
                                alreadyOpen = true; break;
                            }
                        }
                        if (!alreadyOpen) {
                            self.attachToTmux(sessions[i].name);
                            return;
                        }
                    }
                }).catch(function(){});
            }, 1500); // give the native app time to create the workspace and tmux session
        }).catch(function(err) {
            console.error('Failed to create tmux workspace:', err);
        });
    };

    App.prototype.activateTab = function(tab) {
        for (var i = 0; i < this.tabs.length; i++) this.tabs[i].hide();
        for (var j = 0; j < this.splitViews.length; j++) this.splitViews[j].hide();
        this.activeSplit = null;
        tab.show();
        this.activeTab = tab;
        this.renderTabs();
    };

    App.prototype.closeTab = function(tab) {
        tab.close();
        this.tabs = this.tabs.filter(function(t){ return t !== tab; });
        if (this.activeTab === tab) {
            this.activeTab = null;
            if (this.tabs.length > 0) {
                this.activateTab(this.tabs[this.tabs.length - 1]);
            } else if (this.splitViews.length > 0) {
                this.activateSplit(this.splitViews[this.splitViews.length - 1]);
            }
        }
        this.renderTabs();
        this.renderWorkspaces();
        if (this.tabs.length === 0 && this.splitViews.length === 0) {
            var empty = document.getElementById('empty-state');
            if (empty) empty.style.display = '';
        }
    };

    App.prototype.renderTabs = function() {
        var bar = document.getElementById('tab-bar');
        var self = this;
        var items = [];

        // Regular tabs
        for (var i = 0; i < this.tabs.length; i++) {
            var t = this.tabs[i];
            items.push({
                type: 'tab',
                tab: t,
                id: t.id,
                title: t.panelLabel ? t.title + ' / ' + t.panelLabel : t.title,
                tmux: t.tmuxSession,
                isActive: t === self.activeTab && !self.activeSplit
            });
        }

        // Split views (show as single tab entry)
        for (var j = 0; j < this.splitViews.length; j++) {
            var sv = this.splitViews[j];
            var svTitle = sv.tabs.length > 0 ? sv.tabs[0].title : 'Split';
            items.push({
                type: 'split',
                split: sv,
                id: 'split-' + sv.id,
                title: svTitle + ' (Split ' + sv.tabs.length + ')',
                tmux: null,
                isActive: sv === self.activeSplit
            });
        }

        var newHtml = items.map(function(item) {
            var cls = item.isActive ? 'term-tab active' : 'term-tab';
            var tmuxTag = '';
            if (item.tmux) {
                tmuxTag = '<span class="tab-tmux">MIRROR</span>';
            }
            if (item.type === 'split') {
                tmuxTag = '<span class="tab-tmux">SPLIT</span>';
            }
            return '<button class="' + cls + '" data-tab-id="' + item.id + '" data-tab-type="' + item.type + '">'
                + tmuxTag
                + '<span>' + esc(item.title) + '</span>'
                + '<span class="tab-close" data-close="' + item.id + '" data-close-type="' + item.type + '">&times;</span>'
                + '</button>';
        }).join('');

        if (newHtml === this._lastTabsHtml) { return; }
        this._lastTabsHtml = newHtml;
        bar.innerHTML = newHtml;

        bar.querySelectorAll('.term-tab').forEach(function(el) {
            el.addEventListener('click', function(e) {
                var closeEl = e.target;
                while (closeEl && closeEl !== el) {
                    if (closeEl.hasAttribute && closeEl.hasAttribute('data-close')) {
                        var cid = closeEl.getAttribute('data-close');
                        var ctype = closeEl.getAttribute('data-close-type');
                        if (ctype === 'split') {
                            var sv = self.splitViews.find(function(s){ return ('split-' + s.id) === cid; });
                            if (sv) self.closeSplitView(sv);
                        } else {
                            var ct = self.tabs.find(function(t){ return t.id === cid; });
                            if (ct) self.closeTab(ct);
                        }
                        return;
                    }
                    closeEl = closeEl.parentNode;
                }
                var tid = el.getAttribute('data-tab-id');
                var ttype = el.getAttribute('data-tab-type');
                if (ttype === 'split') {
                    var sv = self.splitViews.find(function(s){ return ('split-' + s.id) === tid; });
                    if (sv) self.activateSplit(sv);
                } else {
                    var tt = self.tabs.find(function(t){ return t.id === tid; });
                    if (tt) self.activateTab(tt);
                }
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

        var html = '';
        for (var i = 0; i < sessions.length; i++) {
            var s = sessions[i];
            html += '<div class="tmux-item" data-tmux-name="' + esc(s.name) + '">'
                + '<span class="tmux-name">' + esc(s.name) + '</span>'
                + '<span class="tmux-meta">' + s.attached + ' attached &middot; ' + s.windowCount + ' win</span>'
                + '</div>';
        }

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
        var existing = null;
        for (var i = 0; i < this.tabs.length; i++) {
            if (this.tabs[i].tmuxSession === sessionName) { existing = this.tabs[i]; break; }
        }
        if (existing) {
            this.activateTab(existing);
            this.closeSidebarIfMobile();
            return;
        }

        var empty = document.getElementById('empty-state');
        if (empty) empty.style.display = 'none';

        var tab = new TerminalTab('tmux-' + sessionName, '~', sessionName, sessionName);
        this.tabs.push(tab);
        tab.open(document.getElementById('terminal-container'));
        this.activateTab(tab);
        this.renderTabs();
        this.closeSidebarIfMobile();
    };

    App.prototype.killAllTmuxSessions = function() {
        if (!confirm('Kill all anterminal tmux sessions? Active terminals will be disconnected.')) return;
        var self = this;
        fetch('/api/tmux/sessions', { method: 'DELETE' }).then(function(r) { return r.json(); }).then(function(data) {
            // Close all tmux-attached tabs
            var toClose = [];
            for (var i = 0; i < self.tabs.length; i++) {
                if (self.tabs[i].tmuxSession) toClose.push(self.tabs[i]);
            }
            for (var j = 0; j < toClose.length; j++) {
                self.closeTab(toClose[j]);
            }
            self._tmuxSessionData = [];
            self.renderTmuxSessions([]);
            self.fetchWorkspaces();
        }).catch(function(){});
    };

    /* ---- settings panel ---- */
    App.prototype.openSettings = function() {
        document.getElementById('settings-port').textContent = location.port || '80';
        document.getElementById('settings-clients').textContent = '--';
        document.getElementById('settings-version').textContent = '--';
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
        var tabsCopy = this.tabs.slice();
        for (var i = 0; i < tabsCopy.length; i++) {
            this.closeTab(tabsCopy[i]);
        }
        var svCopy = this.splitViews.slice();
        for (var j = 0; j < svCopy.length; j++) {
            this.closeSplitView(svCopy[j]);
        }
        this.closeSettings();
    };

    /* ---- collapsible sections ---- */
    App.prototype.toggleSection = function(name) {
        var sectionId = name + '-section';
        var section = document.getElementById(sectionId);
        if (!section) return;
        var header = section.querySelector('.sidebar-section-header');
        var body = section.querySelector('.sidebar-section-body');
        if (!header || !body) return;
        var isCollapsed = body.classList.contains('collapsed');
        if (isCollapsed) {
            body.classList.remove('collapsed');
            header.classList.remove('collapsed');
        } else {
            body.classList.add('collapsed');
            header.classList.add('collapsed');
        }
    };

    /* ---- Claude Code sessions ---- */
    App.prototype.fetchCCSessions = function() {
        var self = this;
        fetch('/api/cc/sessions').then(function(r){ return r.json(); }).then(function(data) {
            self.ccSessions = data || [];
            self.renderCCSessions();
        }).catch(function(){});
    };

    App.prototype.renderCCSessions = function() {
        var el = document.getElementById('cc-sessions');
        var section = document.getElementById('cc-section');
        if (!this.ccSessions || !this.ccSessions.length) {
            if (section) section.style.display = 'none';
            if ('' !== this._lastCCHtml) {
                this._lastCCHtml = '';
                if (el) el.innerHTML = '';
            }
            return;
        }
        if (section) section.style.display = '';

        // Group by project, show most recent session per project
        var byProject = {};
        for (var i = 0; i < this.ccSessions.length; i++) {
            var s = this.ccSessions[i];
            if (!byProject[s.projectPath] || new Date(s.lastModified) > new Date(byProject[s.projectPath].lastModified)) {
                byProject[s.projectPath] = s;
            }
        }

        var projects = [];
        for (var k in byProject) {
            if (byProject.hasOwnProperty(k)) projects.push(byProject[k]);
        }
        projects.sort(function(a, b){ return new Date(b.lastModified) - new Date(a.lastModified); });

        var html = '';
        var limit = Math.min(projects.length, 15);
        for (var j = 0; j < limit; j++) {
            var p = projects[j];
            html += '<div class="cc-item" data-cc-path="' + esc(p.projectPath) + '">'
                + '<div class="cc-name">' + esc(p.projectName) + '</div>'
                + '<div class="cc-meta">' + esc(p.projectPath) + ' &middot; ' + timeAgo(p.lastModified) + '</div>'
                + '</div>';
        }

        if (html === this._lastCCHtml) { return; }
        this._lastCCHtml = html;
        el.innerHTML = html;

        var self = this;
        el.querySelectorAll('.cc-item').forEach(function(item) {
            item.addEventListener('click', function() {
                var path = item.getAttribute('data-cc-path');
                self.resumeCCSession(path);
            });
        });
    };

    App.prototype.resumeCCSession = function(projectPath) {
        var self = this;
        fetch('/api/cc/resume', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ projectPath: projectPath })
        }).then(function(r){ return r.json(); }).then(function(data) {
            if (data.ok) {
                // Wait for the workspace to appear, then refresh
                setTimeout(function() { self.fetchWorkspaces(); }, 1500);
            }
        }).catch(function(){});
    };

    /* ---- pane splitting ---- */
    App.prototype.splitActivePanel = function(direction) {
        var wsId = null;
        if (this.activeSplit && this.activeSplit.id) {
            wsId = this.activeSplit.id;
        } else if (this.activeTab && this.activeTab.workspaceId) {
            wsId = this.activeTab.workspaceId;
        }
        if (!wsId) return;
        var self = this;
        fetch('/api/workspaces/' + encodeURIComponent(wsId) + '/split', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ direction: direction || 'right' })
        }).then(function(r){ return r.json(); }).then(function(data) {
            if (data.ok) {
                setTimeout(function() { self.fetchWorkspaces(); }, 1000);
            }
        }).catch(function(){});
    };

    /* ---- helpers ---- */
    function esc(s) {
        if (!s) return '';
        var d = document.createElement('div');
        d.appendChild(document.createTextNode(s));
        return d.innerHTML;
    }

    function timeAgo(isoStr) {
        if (!isoStr) return '';
        var diff = Date.now() - new Date(isoStr).getTime();
        if (diff < 0) diff = 0;
        if (diff < 60000) return 'just now';
        if (diff < 3600000) return Math.floor(diff / 60000) + 'm ago';
        if (diff < 86400000) return Math.floor(diff / 3600000) + 'h ago';
        return Math.floor(diff / 86400000) + 'd ago';
    }

    /* ---- bootstrap ---- */
    var appInstance = new App();
    window.app = appInstance;
    appInstance.init();
    appInstance.loadTmuxSessions();
    // Refresh CC sessions every 30s
    setInterval(function(){ appInstance.fetchCCSessions(); }, 30000);
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
