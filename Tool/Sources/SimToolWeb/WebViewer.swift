import Foundation

public enum WebViewer {
    public static func html(title: String = "SimTool") -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escape(title))</title>
          <style>\(css)</style>
        </head>
        <body>
          <main>
            <section id="viewerCard" class="viewer-card">
              <div id="cardResizeLeft" class="card-resize-handle left" title="Drag to resize"></div>
              <div id="cardResizeRight" class="card-resize-handle right" title="Drag to resize"></div>
              <header class="appbar">
                <div class="brandrow"><p class="brand">SIMTOOL</p></div>
                <div class="toolrow">
                  <button id="home" class="icon-btn" type="button" title="Home">🏠</button>
                  <button id="shot" class="icon-btn" type="button" title="Screenshot">📸</button>
                  <button id="shake" class="icon-btn" type="button" title="Shake">📳</button>
                  <button id="terminate" class="icon-btn" type="button" title="Terminate app">⏹️</button>
                  <button id="relaunch" class="icon-btn" type="button" title="Relaunch app">▶️</button>
                  <button id="inspectToggle" class="inspect-toggle" type="button" aria-pressed="false">
                    <span class="dot"></span><span>Inspect</span>
                  </button>
                </div>
              </header>
              <div id="stage" class="stage">
                <div id="screenWrap" class="screen-wrap fit">
                  <div id="surface" class="surface">
                    <canvas id="screen" aria-label="Simulator stream"></canvas>
                    <div id="axOverlay" class="ax-overlay" hidden></div>
                    <div id="testPlayback" class="test-playback" hidden>
                      <button id="testBackLive" class="test-back-live" type="button">← Live</button>
                      <!-- Custom controls: Orca's embedded browser drops clicks on the
                           <video> element itself, so native controls are unreachable. -->
                      <video id="testVideo" class="test-video" playsinline></video>
                      <div id="testVideoNote" class="test-video-note" hidden>video unavailable</div>
                      <div id="testControls" class="test-controls">
                        <button id="testPlayPause" class="test-ctl-btn" type="button" title="Play/Pause">▶</button>
                        <span id="testTime" class="test-ctl-time">0:00 / 0:00</span>
                        <input id="testSeek" class="test-ctl-seek" type="range" min="0" max="1000" value="0" step="1">
                      </div>
                    </div>
                  </div>
                  <div id="placeholder">connecting…</div>
                  <div class="statusbar">
                    <span id="statusDot" class="status-dot idle"></span>
                    <span id="statusText">opening stream</span>
                    <span id="fps">-- fps</span>
                    <span id="deviceName" class="device-name">—</span>
                  </div>
                </div>
                <aside id="inspector" class="inspector" hidden>
                  <div id="drawerHandle" class="drawer-handle" title="Drag to resize"><span class="grab"></span></div>
                  <div id="inspectorListView" class="inspector-list-view">
                    <div class="inspector-tabs">
                      <button id="tabNetwork" class="insp-tab active" type="button" data-tab="network">Network <span id="networkCount" class="tab-count">0</span></button>
                      <button id="tabLogs" class="insp-tab" type="button" data-tab="logs">Logs <span id="logsCount" class="tab-count">0</span></button>
                      <button id="tabState" class="insp-tab" type="button" data-tab="state">State <span id="stateCount" class="tab-count">0</span></button>
                      <button id="tabAx" class="insp-tab insp-tab-soon" type="button" data-tab="ax">AX</button>
                      <button id="tabTests" class="insp-tab" type="button" data-tab="tests">Tests <span id="testsCount" class="tab-count">0</span></button>
                    </div>
                    <div class="filter-row">
                      <div id="filterField" class="filter-field">
                        <span id="filterChips" class="filter-chips"></span>
                        <input id="inspectorFilter" class="inspector-filter" type="search" placeholder="filter service / status / host" />
                      </div>
                      <button id="filterHelp" class="filter-help" type="button" title="Filter help">?</button>
                    </div>
                    <div id="inspectorNotice" class="inspector-notice" hidden>
                      <b>No app attached</b> — Network, Logs and State need the app relaunched by simtool.
                      Restart the server as
                      <code id="inspectorNoticeCmd" title="Click to copy">simtool serve --app &lt;bundle-id&gt;</code>
                      or run <code id="inspectorNoticeRunCmd" title="Click to copy">simtool run --web</code> from your project.
                    </div>
                    <div id="logsControls" class="logs-controls" hidden>
                      <span id="logsStatus">idle</span>
                    </div>
                    <ul id="networkList" class="network-list scroll-pane"></ul>
                    <ul id="logsList" class="logs-list scroll-pane" hidden></ul>
                    <div id="axPane" class="ax-pane" hidden>
                      <div class="ax-toolbar">
                        <button id="axRefresh" class="ax-refresh" type="button" title="Refresh tree">⟳</button>
                        <span id="axStatus" class="ax-status">—</span>
                      </div>
                      <div id="axSelectedBar" class="ax-selected-bar" hidden>
                        <span id="axSelectedLabel" class="ax-selected-label">—</span>
                        <button id="axCopy" class="ax-copy" type="button" title="Copy this element's full JSON. Right-click any element on screen or row in the tree for a Copy menu.">Copy JSON</button>
                      </div>
                      <div id="axTree" class="ax-tree"></div>
                    </div>
                    <div id="statePane" class="state-pane" hidden>
                      <div id="stateModels" class="state-models"></div>
                      <div id="stateHistory" class="state-history"></div>
                    </div>
                    <div id="testsPane" class="tests-pane" hidden>
                      <div id="testsFlows" class="flows-list"></div>
                      <div class="tests-section-header">Sessions</div>
                      <div id="testsSessions" class="tests-sessions"></div>
                      <div id="testsTimeline" class="tests-timeline scroll-pane"></div>
                    </div>
                  </div>
                  <div id="inspectorDetailView" class="inspector-detail-view" hidden>
                    <button id="detailBack" class="detail-back" type="button">‹ <span id="detailBackLabel">Network</span></button>
                    <div id="detailBody" class="network-detail scroll-pane"></div>
                  </div>
                </aside>
              </div>
            </section>
            <div id="axMenu" class="ax-menu" hidden>
              <button id="axMenuCopy" class="ax-menu-item" type="button">Copy element</button>
            </div>
            <div id="networkMenu" class="ax-menu" hidden>
              <button id="networkMenuExclude" class="ax-menu-item" type="button">Exclude</button>
              <button id="networkMenuInclude" class="ax-menu-item" type="button">Include</button>
            </div>
            <div id="networkLaunchMenu" class="ax-menu" hidden>
              <button id="networkLaunchMenuDelete" class="ax-menu-item tests-menu-delete" type="button">Delete section</button>
            </div>
            <div id="logsMenu" class="ax-menu" hidden>
              <button id="logsMenuCopy" class="ax-menu-item" type="button">Copy entry</button>
              <button id="logsMenuCopySel" class="ax-menu-item" type="button">Copy Selected</button>
              <button id="logsMenuIncludeSel" class="ax-menu-item" type="button">Include Selected</button>
              <button id="logsMenuExcludeSel" class="ax-menu-item" type="button">Exclude Selected</button>
            </div>
            <div id="logsLaunchMenu" class="ax-menu" hidden>
              <button id="logsLaunchMenuDelete" class="ax-menu-item tests-menu-delete" type="button">Delete section</button>
            </div>
            <div id="testsMenu" class="ax-menu" hidden>
              <button id="testsMenuDelete" class="ax-menu-item tests-menu-delete" type="button">Delete</button>
            </div>
            <div id="filterHelpPop" class="filter-help-pop" hidden>
              <p><b>type text</b> — live substring filter over the current tab's fields</p>
              <p><b>Enter</b> — turn the text into an include chip (show only matches)</p>
              <p><b>-text + Enter</b> — exclude chip (hide matches)</p>
              <p data-tab="logs"><b>subsystem:text</b> — match that field only; also message / category / process / level</p>
              <p data-tab="network"><b>right-click a request</b> — include/exclude its path</p>
              <p data-tab="logs"><b>right-click selected text</b> — copy / include / exclude it</p>
            </div>
          </main>
          <script>\(javascript)</script>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root { color-scheme: dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: radial-gradient(circle at top left, #25314a 0, #0b1020 34rem, #05070d 100%); color: #f4f7fb; }
    main { min-height: 100vh; display: grid; place-items: center; padding: 16px; }
    .viewer-card { position: relative; width: min(var(--card-w, 720px), calc(100vw - 32px)); height: calc(100vh - 32px); display: grid; grid-template-rows: auto minmax(0, 1fr); border: 1px solid rgba(255,255,255,0.12); border-radius: 22px; overflow: hidden; background: rgba(7, 10, 18, 0.78); box-shadow: 0 24px 80px rgba(0,0,0,0.45); backdrop-filter: blur(20px); }
    .card-resize-handle { position: absolute; top: 0; bottom: 0; width: 6px; z-index: 5; cursor: ew-resize; touch-action: none; }
    .card-resize-handle.left { left: 0; }
    .card-resize-handle.right { right: 0; }
    .card-resize-handle:hover, .card-resize-handle.active { background: rgba(125,211,252,0.25); }
    a { color: #7dd3fc; }

    /* App bar: SIMTOOL on top, device actions + Inspect toggle below */
    .appbar { border-bottom: 1px solid rgba(255,255,255,0.08); background: rgba(255,255,255,0.025); }
    .brandrow { padding: 9px 16px 2px; }
    .brand { margin: 0; color: #7dd3fc; font-size: 12px; letter-spacing: 0.14em; text-transform: uppercase; font-weight: 700; }
    .toolrow { display: flex; align-items: center; gap: 8px; padding: 4px 14px 10px; }
    .icon-btn { appearance: none; width: 30px; height: 30px; display: grid; place-items: center; border: 1px solid rgba(255,255,255,0.14); border-radius: 9px; background: rgba(255,255,255,0.06); color: #cdd6e6; font-size: 14px; cursor: pointer; }
    .icon-btn:hover { background: rgba(255,255,255,0.10); }
    .inspect-toggle { margin-left: auto; display: flex; align-items: center; gap: 7px; appearance: none; border: 1px solid rgba(255,255,255,0.14); border-radius: 10px; background: rgba(255,255,255,0.06); color: rgba(244,247,251,0.72); padding: 6px 12px; font: 12px ui-sans-serif, system-ui, sans-serif; cursor: pointer; }
    .inspect-toggle:hover { background: rgba(255,255,255,0.10); }
    .inspect-toggle .dot { width: 8px; height: 8px; border-radius: 999px; background: #4b5366; }
    .inspect-toggle.on { background: rgba(125,211,252,0.16); border-color: transparent; color: #bae6fd; }
    .inspect-toggle.on .dot { background: #7dd3fc; box-shadow: 0 0 8px rgba(125,211,252,0.85); }

    /* Stage holds the device behind the drawer; the status bar and inspector overlay its bottom. */
    .stage { position: relative; min-height: 0; background: #000; overflow: hidden; }
    .screen-wrap { position: absolute; inset: 0; padding: 16px; }
    .screen-wrap.fit { display: grid; place-items: center; overflow: hidden; }
    .screen-wrap.actual { display: grid; justify-items: center; align-items: start; overflow: auto; }
    .surface { position: relative; width: 360px; height: 780px; max-width: 100%; max-height: 100%; border-radius: 22px; overflow: hidden; background: #03040a; box-shadow: 0 0 0 1px rgba(255,255,255,0.10), 0 22px 60px rgba(0,0,0,0.36); }
    canvas { display: block; width: 100%; height: 100%; object-fit: contain; image-rendering: auto; cursor: crosshair; touch-action: none; }
    #placeholder { position: absolute; inset: 0; display: grid; place-items: center; color: rgba(255,255,255,0.52); font-size: 13px; pointer-events: none; }

    .statusbar { position: absolute; left: 0; right: 0; bottom: 0; z-index: 1; display: flex; align-items: center; gap: 8px; padding: 6px 12px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.64); background: linear-gradient(rgba(3,5,12,0), rgba(3,5,12,0.74)); pointer-events: none; }
    .status-dot { width: 7px; height: 7px; border-radius: 999px; background: #4ade80; box-shadow: 0 0 6px rgba(74,222,128,0.7); }
    .status-dot.err { background: #f87171; box-shadow: 0 0 6px rgba(248,113,113,0.7); }
    .status-dot.idle { background: #4b5366; box-shadow: none; }
    .statusbar .device-name { margin-left: auto; color: #bae6fd; }

    /* Inspector drawer: always slides up from the bottom over the device. */
    .inspector { position: absolute; left: 0; right: 0; bottom: 0; z-index: 3; height: 62%; display: flex; flex-direction: column; min-height: 0; background: #0b1020; border-top: 1px solid rgba(255,255,255,0.10); border-radius: 16px 16px 0 0; box-shadow: 0 -12px 32px rgba(0,0,0,0.55); }
    .inspector[hidden] { display: none; }
    .drawer-handle { flex: 0 0 auto; display: grid; place-items: center; padding: 6px 0 4px; cursor: row-resize; touch-action: none; }
    .drawer-handle .grab { width: 34px; height: 4px; border-radius: 999px; background: rgba(255,255,255,0.28); }
    .drawer-handle:hover .grab { background: rgba(255,255,255,0.45); }

    /* Side-by-side layout: when the stage is wide enough, the inspector docks as a right column
       beside the device (both fully visible) instead of overlaying it as a bottom drawer. */
    .stage.layout-side { display: flex; flex-direction: row; }
    .stage.layout-side .screen-wrap { position: relative; inset: auto; flex: 9999 1 0%; min-width: 0; }
    .stage.layout-side.inspector-open .screen-wrap { max-width: 600px; }
    .stage.layout-side .inspector { position: relative; left: auto; right: auto; bottom: auto; z-index: 0; height: auto; flex: 1 0 400px; min-width: 0; border-top: 0; border-left: 1px solid rgba(255,255,255,0.10); border-radius: 0; box-shadow: none; }
    .stage.layout-side .drawer-handle { display: none; }
    .inspector-list-view, .inspector-detail-view { display: flex; flex-direction: column; min-height: 0; flex: 1 1 auto; }
    .inspector-list-view[hidden], .inspector-detail-view[hidden] { display: none; }

    .inspector-tabs { display: flex; align-items: center; gap: 2px; padding: 0 8px; border-bottom: 1px solid rgba(255,255,255,0.08); }
    .insp-tab { appearance: none; background: none; border: 0; border-bottom: 2px solid transparent; color: rgba(244,247,251,0.55); padding: 8px 10px 7px; font: 12px ui-sans-serif, system-ui, sans-serif; cursor: pointer; display: flex; align-items: center; gap: 6px; }
    .insp-tab:hover { color: #cdd6e6; }
    .insp-tab.active { color: #bae6fd; border-bottom-color: #7dd3fc; }
    .insp-tab .tab-count { font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.5); }
    .insp-tab.active .tab-count { color: #7dd3fc; }
    .state-pane { display: flex; flex-direction: column; gap: 8px; padding: 8px; overflow: auto; flex: 1; min-height: 0; }
    .state-pane[hidden] { display: none; }
    .state-models { display: flex; flex-direction: column; gap: 6px; }
    .state-model { border: 1px solid rgba(255,255,255,0.08); border-radius: 6px; padding: 6px 8px; }
    .state-model.state-dead { opacity: 0.45; }
    .state-model summary { cursor: pointer; font: 12px ui-sans-serif, system-ui, sans-serif; color: #bae6fd; }
    .state-tree { margin: 4px 0 0 12px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: #cdd6e6; }
    .state-history { display: flex; flex-direction: column; gap: 4px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .state-change { border-top: 1px solid rgba(255,255,255,0.06); padding-top: 4px; }
    .state-change-title { color: rgba(244,247,251,0.55); }
    .state-diff-minus { color: #fda4af; }
    .state-diff-plus { color: #86efac; }
    /* Tests tab */
    .tests-pane { display: flex; flex-direction: column; gap: 8px; min-height: 0; flex: 1; padding: 8px; }
    .tests-pane[hidden] { display: none; }
    .tests-sessions { display: flex; flex-direction: column; gap: 4px; max-height: 38%; overflow: auto; flex-shrink: 0; }
    .tests-row { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 6px 10px; border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; cursor: pointer; font-size: 12px; }
    .tests-row:hover { border-color: rgba(125,211,252,0.45); }
    .tests-row.selected { border-color: #7dd3fc; background: rgba(125,211,252,0.08); }
    .tests-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .tests-meta { flex-shrink: 0; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .tests-status-passed { color: #4ade80; }
    .tests-status-failed { color: #f87171; }
    .tests-status-running { color: #fbbf24; }
    .tests-status-interrupted { color: rgba(244,247,251,0.45); }
    .tests-empty { color: rgba(244,247,251,0.45); font-size: 12px; padding: 10px; }
    .tests-section-header { flex-shrink: 0; font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: rgba(244,247,251,0.5); padding: 4px 2px 0; }
    .flows-list { display: flex; flex-direction: column; gap: 4px; max-height: 30%; overflow: auto; flex-shrink: 0; }
    .flows-row { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; font-size: 12px; }
    .flows-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .flows-desc { margin-top: 2px; font-size: 11px; color: rgba(244,247,251,0.5); white-space: normal; overflow-wrap: anywhere; }
    .flows-meta { flex-shrink: 0; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.5); }
    .flows-error { color: #f87171; }
    .flows-run { flex-shrink: 0; cursor: pointer; border: 1px solid rgba(125,211,252,0.45); background: none; color: #7dd3fc; border-radius: 6px; padding: 2px 10px; font-size: 11px; }
    .flows-run:hover:not(:disabled) { background: rgba(125,211,252,0.10); }
    .flows-run:disabled { opacity: 0.4; cursor: default; }
    .tests-timeline { display: flex; flex-direction: column; gap: 3px; min-height: 0; flex: 1; overflow: auto; }
    .tests-timeline-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 8px; font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: rgba(244,247,251,0.5); padding: 4px 2px; }
    .tests-timeline-title { flex: 1; min-width: 0; overflow-wrap: anywhere; }
    .tests-timeline-toggle { flex: 0 0 auto; cursor: pointer; user-select: none; color: rgba(244,247,251,0.5); padding: 2px 6px; font-size: 18px; line-height: 1; }
    .tests-timeline-toggle:hover { color: #7dd3fc; }
    .tests-step { display: flex; align-items: flex-start; gap: 8px; padding: 5px 8px; border-radius: 6px; border: 1px solid transparent; cursor: pointer; font-size: 12px; }
    .tests-step:hover { border-color: rgba(125,211,252,0.45); }
    .tests-step.current { border-color: #7dd3fc; background: rgba(125,211,252,0.10); }
    .tests-step-t { flex: 0 0 38px; color: #7dd3fc; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .tests-step-text { flex: 1; min-width: 0; }
    .tests-step-toggle { flex: 0 0 auto; color: rgba(244,247,251,0.5); cursor: pointer; user-select: none; padding: 0 4px; font-size: 16px; line-height: 1; }
    .tests-step-toggle:hover { color: #7dd3fc; }
    .tests-detail { margin-left: 46px; display: flex; flex-direction: column; gap: 3px; padding: 2px 0 4px; }
    .tests-detail[hidden] { display: none; }
    .tests-detail-text { padding: 2px 8px; font-size: 12px; color: rgba(244,247,251,0.7); }
    .tests-logline { margin-left: 46px; padding: 2px 8px; border-left: 2px solid rgba(74,222,128,0.5); font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(190,242,164,0.85); word-break: break-all; }
    .tests-detail .tests-logline { margin-left: 0; }
    .tests-log { display: flex; gap: 8px; padding: 3px 8px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(190,242,164,0.85); word-break: break-all; }
    /* Test session playback over the screen pane */
    .test-playback { position: absolute; inset: 0; z-index: 2; display: flex; flex-direction: column; background: #03040a; }
    .test-playback[hidden] { display: none; }
    .test-back-live { align-self: flex-start; margin: 8px 0 8px 10px; padding: 4px 10px; border: 1px solid rgba(125,211,252,0.6); border-radius: 8px; background: rgba(7,10,18,0.8); color: #bae6fd; font-size: 12px; cursor: pointer; }
    .test-back-live:hover { background: rgba(125,211,252,0.18); }
    .test-video { flex: 1; min-height: 0; width: 100%; object-fit: contain; }
    .test-controls { flex: 0 0 auto; display: flex; align-items: center; gap: 10px; padding: 8px 12px; background: rgba(11,16,32,0.92); border-top: 1px solid rgba(255,255,255,0.10); }
    .test-ctl-btn { flex: 0 0 auto; width: 32px; height: 26px; cursor: pointer; border: 1px solid rgba(125,211,252,0.45); background: none; color: #7dd3fc; border-radius: 6px; font-size: 12px; line-height: 1; }
    .test-ctl-btn:hover { background: rgba(125,211,252,0.10); }
    .test-ctl-time { flex: 0 0 auto; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.75); }
    .test-ctl-seek { flex: 1; min-width: 0; accent-color: #7dd3fc; cursor: pointer; }
    .test-video-note { position: absolute; left: 0; right: 0; bottom: 52px; z-index: 6; text-align: center; color: rgba(244,247,251,0.6); font-size: 11px; pointer-events: none; }
    .insp-tab-soon { color: rgba(244,247,251,0.32); }
    .filter-row { display: flex; align-items: center; gap: 6px; padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.08); }
    .filter-field { flex: 1 1 auto; min-width: 0; display: flex; flex-wrap: wrap; align-items: center; gap: 3px; padding: 2px 4px; background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.14); border-radius: 8px; }
    .filter-field:focus-within { border-color: rgba(125,211,252,0.5); }
    .filter-chips { display: contents; }
    .inspector-filter { min-width: 60px; width: 110px; flex: 1 1 60px; background: none; border: 0; outline: none; color: #f4f7fb; padding: 2px 4px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .filter-chip { display: inline-flex; align-items: center; gap: 4px; max-width: 150px; padding: 1px 4px 1px 6px; border-radius: 6px; border: 1px solid; font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .filter-chip.include { color: #86efac; border-color: rgba(74,222,128,0.4); background: rgba(74,222,128,0.10); }
    .filter-chip.exclude { color: #fda4af; border-color: rgba(248,113,113,0.4); background: rgba(248,113,113,0.10); }
    .filter-chip .chip-term { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .filter-chip-x { appearance: none; border: 0; background: none; color: inherit; cursor: pointer; padding: 0 2px; font-size: 9px; opacity: 0.65; }
    .filter-chip-x:hover { opacity: 1; }
    .filter-help { appearance: none; flex: 0 0 auto; width: 18px; height: 18px; display: grid; place-items: center; border: 1px solid rgba(255,255,255,0.14); border-radius: 999px; background: rgba(255,255,255,0.06); color: rgba(244,247,251,0.6); font-size: 10px; cursor: pointer; }
    .filter-help:hover { background: rgba(255,255,255,0.10); color: #cdd6e6; }
    .filter-help[hidden] { display: none; }
    .filter-help-pop { position: fixed; z-index: 10; max-width: 300px; padding: 8px 10px; background: #0b1020; border: 1px solid rgba(255,255,255,0.16); border-radius: 9px; box-shadow: 0 12px 32px rgba(0,0,0,0.55); font: 11px ui-sans-serif, system-ui, sans-serif; color: rgba(244,247,251,0.85); }
    .filter-help-pop[hidden] { display: none; }
    .filter-help-pop p { margin: 0 0 6px; }
    .filter-help-pop p:last-child { margin-bottom: 0; }
    .filter-help-pop b { color: #bae6fd; }
    .inspector-filter:disabled { opacity: 0.4; cursor: not-allowed; }

    .logs-controls { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.08); }
    .logs-controls[hidden] { display: none; }
    .inspector-notice { padding: 8px 10px; border-bottom: 1px solid rgba(255,193,7,0.25); background: rgba(255,193,7,0.10); color: #ffd869; font: 12px/1.5 -apple-system, system-ui, sans-serif; }
    .inspector-notice[hidden] { display: none; }
    .inspector-notice code { padding: 1px 5px; border-radius: 4px; background: rgba(0,0,0,0.35); color: #ffe9a8; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; cursor: pointer; overflow-wrap: anywhere; }
    .inspector-notice code:hover { background: rgba(0,0,0,0.55); }
    /* The serve command carries a UDID and never fits inline: give it its own wrapped line. */
    .inspector-notice #inspectorNoticeCmd { display: block; margin: 4px 0; padding: 4px 8px; }
    #logsStatus { font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.55); white-space: nowrap; }

    .scroll-pane { overflow: auto; flex: 1 1 auto; min-height: 0; }
    .scroll-pane[hidden] { display: none; }

    .network-list { list-style: none; margin: 0; padding: 0; }
    .network-row { display: grid; grid-template-columns: 52px 1fr auto auto; gap: 8px; align-items: center; padding: 6px 10px; cursor: pointer; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; border-bottom: 1px solid rgba(255,255,255,0.05); }
    .network-row:hover { background: rgba(255,255,255,0.05); }
    .network-row.selected { background: rgba(125,211,252,0.14); }
    .network-row .req { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .network-row .time { color: rgba(244,247,251,0.5); }
    .network-row .status { font-weight: 700; }
    .network-row .dur { color: rgba(244,247,251,0.6); }
    .network-row.mocked { border-left: 3px solid #a78bfa; }
    .network-row .mock-badge { color: #a78bfa; margin-left: 4px; }
    .status-ok { color: #4ade80; }
    .status-warn { color: #fbbf24; }
    .status-err { color: #f87171; }

    .network-detail { padding: 10px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.86); }
    .network-detail h3 { margin: 10px 0 4px; font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: #7dd3fc; }
    .network-detail h3:first-child { margin-top: 0; }
    .network-detail pre { white-space: pre-wrap; word-break: break-word; margin: 0 0 6px; padding: 6px 8px; border-radius: 8px; background: rgba(255,255,255,0.04); }
    .network-detail .kv { display: grid; grid-template-columns: minmax(96px, 38%) 1fr; column-gap: 12px; row-gap: 3px; margin: 0 0 6px; padding: 6px 8px; border-radius: 8px; background: rgba(255,255,255,0.04); }
    .network-detail .kv-key { color: rgba(125,211,252,0.82); overflow-wrap: anywhere; }
    .network-detail .kv-val { color: rgba(244,247,251,0.92); overflow-wrap: anywhere; }
    .network-detail .mock-value { color: #a78bfa; }
    .network-detail details.mock-rule { margin: 0 0 6px; padding: 6px 8px; border-radius: 8px; background: rgba(167,139,250,0.08); }
    .network-detail details.mock-rule summary { cursor: pointer; color: #a78bfa; font-weight: 700; }
    .network-detail details.mock-rule pre { margin: 6px 0 0; background: transparent; padding: 0; }
    .network-empty, .logs-empty { color: rgba(244,247,251,0.5); padding: 10px; display: block; }

    .detail-back { appearance: none; width: 100%; text-align: left; background: rgba(255,255,255,0.03); border: 0; border-bottom: 1px solid rgba(255,255,255,0.08); color: #bae6fd; padding: 8px 12px; font: 12px ui-sans-serif, system-ui, sans-serif; cursor: pointer; }
    .detail-back:hover { background: rgba(255,255,255,0.06); }

    .logs-list { list-style: none; margin: 0; padding: 0; }
    .logs-row { position: relative; padding: 2px 52px 2px 10px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; border-bottom: 1px solid rgba(255,255,255,0.04); cursor: pointer; }
    .logs-row:hover { background: rgba(255,255,255,0.05); }
    .logs-row .time { position: absolute; top: 2px; right: 8px; font-size: 9px; opacity: 0.5; pointer-events: none; }
    .logs-row .lvl { font-weight: 700; opacity: 0.75; margin-right: 4px; }
    .logs-row .msg { white-space: pre-wrap; word-break: break-word; }
    .logs-src-oslog { color: #7dd3fc; }
    .logs-src-stdout { color: #4ade80; }
    .logs-row-error { background: rgba(248,113,113,0.08); }
    .logs-row-error .msg, .logs-row-error .lvl { color: #f87171; font-weight: 600; }

    /* AX inspector: toolbar + selected-element bar + scrollable tree. */
    .ax-pane { display: flex; flex-direction: column; min-height: 0; flex: 1 1 auto; }
    .ax-pane[hidden] { display: none; }
    .ax-toolbar { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.08); }
    .ax-refresh { appearance: none; width: 26px; height: 24px; display: grid; place-items: center; border: 1px solid rgba(255,255,255,0.14); border-radius: 7px; background: rgba(255,255,255,0.06); color: #cdd6e6; cursor: pointer; font-size: 13px; }
    .ax-refresh:hover { background: rgba(255,255,255,0.10); }
    .ax-status { font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.55); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ax-selected-bar { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.08); background: rgba(125,211,252,0.06); }
    .ax-selected-bar[hidden] { display: none; }
    .ax-selected-label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: #bae6fd; }
    .ax-copy { appearance: none; border: 1px solid rgba(125,211,252,0.4); border-radius: 7px; background: rgba(125,211,252,0.14); color: #bae6fd; padding: 4px 10px; font: 11px ui-sans-serif, system-ui, sans-serif; cursor: pointer; white-space: nowrap; }
    .ax-copy:hover { background: rgba(125,211,252,0.22); }
    .ax-tree { overflow: auto; flex: 1 1 auto; min-height: 0; padding: 4px 0; }
    /* Rows size to their content so deep indentation scrolls horizontally
       instead of squeezing the primary label down to a clipped glyph. */
    .ax-row { display: flex; align-items: center; gap: 6px; padding: 3px 10px 3px 0; cursor: pointer; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; white-space: nowrap; width: max-content; min-width: 100%; }
    .ax-row:hover { background: rgba(255,255,255,0.05); }
    .ax-row.selected { background: rgba(125,211,252,0.16); }
    .ax-chevron { display: inline-block; width: 12px; text-align: center; color: rgba(244,247,251,0.5); flex: 0 0 auto; }
    .ax-label { color: #f4f7fb; flex: 0 0 auto; }
    .ax-text { color: rgba(244,247,251,0.72); flex: 0 0 auto; }
    .ax-secondary { color: rgba(244,247,251,0.4); flex: 0 0 auto; }
    .ax-empty { display: block; padding: 12px; color: rgba(244,247,251,0.5); font: 12px ui-sans-serif, system-ui, sans-serif; }

    /* AX overlays drawn over the device image (never into the video canvas). */
    .ax-overlay { position: absolute; inset: 0; pointer-events: none; z-index: 2; }
    .ax-overlay[hidden] { display: none; }
    .ax-box { position: absolute; border: 1px solid rgba(125,211,252,0.32); box-sizing: border-box; }
    .ax-box.hover { border-color: rgba(125,211,252,0.85); background: rgba(125,211,252,0.12); }
    .ax-box.selected { border: 2px solid #7dd3fc; background: rgba(125,211,252,0.20); box-shadow: 0 0 0 1px rgba(7,10,18,0.6); }
    canvas.ax-pick { cursor: default; }

    /* Right-click context menu (Copy element). */
    .ax-menu { position: fixed; z-index: 10; min-width: 140px; padding: 4px; background: #0b1020; border: 1px solid rgba(255,255,255,0.16); border-radius: 9px; box-shadow: 0 12px 32px rgba(0,0,0,0.55); }
    .ax-menu[hidden] { display: none; }
    .ax-menu-item { appearance: none; display: block; width: 100%; text-align: left; background: none; border: 0; border-radius: 6px; color: #f4f7fb; padding: 7px 10px; font: 12px ui-sans-serif, system-ui, sans-serif; cursor: pointer; white-space: nowrap; }
    .ax-menu-item:hover { background: rgba(125,211,252,0.18); color: #bae6fd; }
    .tests-menu-delete { color: #f87171; }
    .tests-menu-delete:hover { background: rgba(248,113,113,0.16); color: #fca5a5; }

    /* Launch dividers stay sticky and collapsible across the network and logs lists. */
    .launch-divider { position: sticky; top: 0; z-index: 2; list-style: none; margin: 0; padding: 4px 10px; display: flex; align-items: center; gap: 6px; font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(125,211,252,0.9); background: linear-gradient(rgba(125,211,252,0.08), rgba(125,211,252,0.08)), #070b15; border-top: 1px solid rgba(125,211,252,0.28); border-bottom: 1px solid rgba(125,211,252,0.18); letter-spacing: 0.04em; cursor: pointer; user-select: none; }
    .launch-divider:hover { background: linear-gradient(rgba(125,211,252,0.16), rgba(125,211,252,0.16)), #070b15; }
    .launch-divider:focus-visible { outline: 1px solid rgba(125,211,252,0.6); outline-offset: -1px; }
    .launch-divider .launch-chevron { display: inline-block; width: 10px; text-align: center; opacity: 0.85; }
    .launch-divider .launch-label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

    @media (max-width: 720px) {
      main { padding: 0; }
      .viewer-card { width: 100vw; height: 100vh; border-radius: 0; border: 0; }
      .card-resize-handle { display: none; }
    }
    """

    private static let javascript = #"""
    const $ = (id) => document.getElementById(id);
    const screenWrap = $("screenWrap");
    const surface = $("surface");
    const canvas = $("screen");
    const placeholder = $("placeholder");
    const statusDot = $("statusDot");
    const statusText = $("statusText");
    const fps = $("fps");
    const deviceName = $("deviceName");
    const homeButton = $("home");
    const shotButton = $("shot");
    const shakeButton = $("shake");
    const terminateButton = $("terminate");
    const relaunchButton = $("relaunch");
    const stage = $("stage");

    const inspectToggle = $("inspectToggle");
    const inspector = $("inspector");
    const drawerHandle = $("drawerHandle");
    const inspectorListView = $("inspectorListView");
    const inspectorDetailView = $("inspectorDetailView");
    const detailBack = $("detailBack");
    const detailBackLabel = $("detailBackLabel");
    const detailBody = $("detailBody");
    const inspectorFilter = $("inspectorFilter");
    const tabButtons = { network: $("tabNetwork"), logs: $("tabLogs"), state: $("tabState"), ax: $("tabAx"), tests: $("tabTests") };
    const networkCount = $("networkCount");
    const logsCount = $("logsCount");
    const networkList = $("networkList");
    const inspectorNotice = $("inspectorNotice");
    const inspectorNoticeCmd = $("inspectorNoticeCmd");
    const inspectorNoticeRunCmd = $("inspectorNoticeRunCmd");
    const logsControls = $("logsControls");
    const logsList = $("logsList");
    const axPane = $("axPane");
    const statePane = $("statePane");
    const stateModelsEl = $("stateModels");
    const stateHistoryEl = $("stateHistory");
    const stateCountEl = $("stateCount");
    const axTreeEl = $("axTree");
    const axOverlay = $("axOverlay");
    const axStatusEl = $("axStatus");
    const axRefreshButton = $("axRefresh");
    const axSelectedBar = $("axSelectedBar");
    const axSelectedLabel = $("axSelectedLabel");
    const axCopyButton = $("axCopy");
    const axMenu = $("axMenu");
    const axMenuCopy = $("axMenuCopy");
    const filterChips = $("filterChips");
    const filterHelp = $("filterHelp");
    const filterHelpPop = $("filterHelpPop");
    const networkMenu = $("networkMenu");
    const networkMenuExclude = $("networkMenuExclude");
    const networkMenuInclude = $("networkMenuInclude");
    const networkLaunchMenu = $("networkLaunchMenu");
    const networkLaunchMenuDelete = $("networkLaunchMenuDelete");
    const logsMenu = $("logsMenu");
    const logsMenuCopy = $("logsMenuCopy");
    const logsMenuCopySel = $("logsMenuCopySel");
    const logsMenuIncludeSel = $("logsMenuIncludeSel");
    const logsMenuExcludeSel = $("logsMenuExcludeSel");
    const logsLaunchMenu = $("logsLaunchMenu");
    const logsLaunchMenuDelete = $("logsLaunchMenuDelete");
    const testsMenu = $("testsMenu");
    const testsMenuDelete = $("testsMenuDelete");
    const logsStatus = $("logsStatus");
    const testsPane = $("testsPane");
    const testsSessionsEl = $("testsSessions");
    const testsTimelineEl = $("testsTimeline");
    const testsCountEl = $("testsCount");
    const testsFlowsEl = $("testsFlows");
    const testPlayback = $("testPlayback");
    const testVideo = $("testVideo");
    const testBackLive = $("testBackLive");
    const testVideoNote = $("testVideoNote");

    const canvasContext = canvas.getContext("2d", { alpha: false, desynchronized: true });
    const maxCanvasDPR = 1.5;

    let mode = "fit";
    let streamWidth = 0;
    let streamHeight = 0;

    function setStatus(text, kind) {
      statusText.textContent = text;
      statusDot.className = "status-dot" + (kind === "err" ? " err" : kind === "idle" ? " idle" : "");
    }

    const tags = { 1: "description", 2: "keyframe", 3: "delta" };
    class Demuxer {
      constructor() { this.buffer = new Uint8Array(0); }
      push(bytes) {
        const merged = new Uint8Array(this.buffer.length + bytes.length);
        merged.set(this.buffer);
        merged.set(bytes, this.buffer.length);
        this.buffer = merged;
        const chunks = [];
        let offset = 0;
        while (this.buffer.length - offset >= 4) {
          const length = new DataView(this.buffer.buffer, this.buffer.byteOffset + offset, 4).getUint32(0, false);
          if (length < 1) { offset += 4; continue; }
          if (this.buffer.length - offset - 4 < length) break;
          const tag = this.buffer[offset + 4];
          const type = tags[tag];
          if (type) chunks.push({ type, payload: this.buffer.slice(offset + 5, offset + 4 + length) });
          offset += 4 + length;
        }
        if (offset > 0) this.buffer = this.buffer.slice(offset);
        return chunks;
      }
    }

    function avcCodecString(description) {
      if (description.length < 4) return "avc1.42E01E";
      const h = (b) => b.toString(16).padStart(2, "0");
      return "avc1." + h(description[1]) + h(description[2]) + h(description[3]);
    }

    function updateSurfaceSize() {
      if (!streamWidth || !streamHeight) return;
      const aspect = streamWidth / streamHeight;
      if (mode === "actual") {
        surface.style.width = `${streamWidth}px`;
        surface.style.height = `${streamHeight}px`;
        return;
      }
      const padding = 36;
      const maxW = Math.max(160, screenWrap.clientWidth - padding);
      const maxH = Math.max(160, screenWrap.clientHeight - padding);
      let w = Math.min(maxW, maxH * aspect);
      let h = w / aspect;
      if (h > maxH) { h = maxH; w = h * aspect; }
      surface.style.width = `${Math.floor(w)}px`;
      surface.style.height = `${Math.floor(h)}px`;
    }

    let frameTimes = [];
    function didPaint(w, h) {
      placeholder.style.display = "none";
      streamWidth = w;
      streamHeight = h;
      updateSurfaceSize();
      const now = performance.now();
      frameTimes.push(now);
      frameTimes = frameTimes.filter((t) => now - t < 1000);
      fps.textContent = `${frameTimes.length} fps`;
    }

    function canvasBackingSize(sourceW, sourceH) {
      const rect = canvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return { width: sourceW, height: sourceH };
      const dpr = Math.min(window.devicePixelRatio || 1, maxCanvasDPR);
      return {
        width: Math.max(1, Math.min(sourceW, Math.round(rect.width * dpr))),
        height: Math.max(1, Math.min(sourceH, Math.round(rect.height * dpr)))
      };
    }

    function paint(source, w, h) {
      if (!canvasContext) return;
      const backing = canvasBackingSize(w, h);
      if (canvas.width !== backing.width || canvas.height !== backing.height) {
        canvas.width = backing.width;
        canvas.height = backing.height;
      }
      canvasContext.drawImage(source, 0, 0, backing.width, backing.height);
      didPaint(w, h);
    }

    function makeFramePainter() {
      let pendingFrame = null;
      let scheduled = false;

      function drawPending() {
        scheduled = false;
        const frame = pendingFrame;
        pendingFrame = null;
        if (!frame) return;
        try { paint(frame, frame.displayWidth, frame.displayHeight); }
        finally { frame.close(); }
      }

      return {
        drawDecoded(frame) {
          if (pendingFrame) pendingFrame.close();
          pendingFrame = frame;
          if (!scheduled) {
            scheduled = true;
            requestAnimationFrame(drawPending);
          }
        }
      };
    }

    async function api(path, options = {}) {
      const headers = new Headers(options.headers || {});
      if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
      const response = await fetch(path, { ...options, headers });
      if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
      return response;
    }

    function eventToSimulatorPoint(event, element) {
      const rect = element.getBoundingClientRect();
      const x = (event.clientX - rect.left) * (streamWidth / rect.width);
      const y = (event.clientY - rect.top) * (streamHeight / rect.height);
      return { x, y };
    }

    async function sendTap(point) {
      if (!streamWidth || !streamHeight) return;
      try {
        await api("/api/v1/input", {
          method: "POST",
          body: JSON.stringify({
            action: "tap",
            x: point.x,
            y: point.y,
            coordinateSpace: "pixels",
            sourceWidth: streamWidth,
            sourceHeight: streamHeight
          })
        });
      } catch (error) {
        setStatus(`tap failed: ${error.message}`, "err");
      }
    }

    async function sendSwipe(start, end, durationSeconds) {
      if (!streamWidth || !streamHeight) return;
      try {
        await api("/api/v1/input", {
          method: "POST",
          body: JSON.stringify({
            action: "swipe",
            startX: start.x,
            startY: start.y,
            endX: end.x,
            endY: end.y,
            duration: durationSeconds,
            coordinateSpace: "pixels",
            sourceWidth: streamWidth,
            sourceHeight: streamHeight
          })
        });
      } catch (error) {
        setStatus(`swipe failed: ${error.message}`, "err");
      }
    }

    async function pressHome() {
      try {
        await api("/api/v1/input", { method: "POST", body: JSON.stringify({ action: "button", name: "home" }) });
      } catch (error) {
        setStatus(`home failed: ${error.message}`, "err");
      }
    }

    async function pressShake() {
      try {
        await api("/api/v1/input", { method: "POST", body: JSON.stringify({ action: "shake" }) });
      } catch (error) {
        setStatus(`shake failed: ${error.message}`, "err");
      }
    }

    async function pressTerminate() {
      try {
        await api("/api/v1/input", { method: "POST", body: JSON.stringify({ action: "terminate" }) });
      } catch (error) {
        setStatus(`terminate failed: ${error.message}`, "err");
      }
    }

    async function pressRelaunch() {
      try {
        await api("/api/v1/input", { method: "POST", body: JSON.stringify({ action: "launch" }) });
      } catch (error) {
        setStatus(`relaunch failed: ${error.message}`, "err");
      }
    }

    async function downloadScreenshot() {
      try {
        const response = await api("/api/v1/screenshot");
        const blob = await response.blob();
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = "simtool-screenshot.png";
        link.click();
        URL.revokeObjectURL(url);
      } catch (error) {
        setStatus(`screenshot failed: ${error.message}`, "err");
      }
    }

    async function startAvcc() {
      if (typeof VideoDecoder === "undefined") throw new Error("WebCodecs VideoDecoder is unavailable");
      setStatus("connecting", "idle");
      const demuxer = new Demuxer();
      const framePainter = makeFramePainter();
      let timestamp = 0;
      let decoder = new VideoDecoder({
        output(frame) {
          framePainter.drawDecoded(frame);
        },
        error(error) { setStatus(`decoder error: ${error.message}`, "err"); }
      });
      const response = await fetch("/stream.avcc");
      const reader = response.body.getReader();
      setStatus("live", "live");
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        if (!value) continue;
        for (const chunk of demuxer.push(value)) {
          if (chunk.type === "description") {
            decoder.configure({
              codec: avcCodecString(chunk.payload),
              description: chunk.payload,
              optimizeForLatency: true,
              hardwareAcceleration: "prefer-hardware"
            });
          } else if (decoder.state === "configured") {
            try {
              decoder.decode(new EncodedVideoChunk({
                type: chunk.type === "keyframe" ? "key" : "delta",
                timestamp,
                data: chunk.payload
              }));
              timestamp += 16667;
            } catch (_) {}
          }
        }
      }
      throw new Error("AVCC stream ended");
    }

    // ---- App launches (shared dividers across network + logs) ----

    let launchesById = {};
    const collapsedLogLaunches = new Set();
    const collapsedNetworkLaunches = new Set();
    const expandedTestSteps = new Set();   // "<sessionId>:<entryIndex>" of steps whose detail is open

    async function loadLaunches() {
      try {
        const response = await api("/api/v1/launches");
        const payload = await response.json();
        const map = {};
        for (const launch of (payload.launches || [])) map[launch.launchId] = launch;
        launchesById = map;
      } catch (_) {}
    }

    // Renders an ISO8601 timestamp (stored in UTC) as a local HH:MM:SS clock.
    // Falls back to the raw UTC time slice if the string isn't a parseable date.
    function clockTime(iso) {
      if (!iso) return "";
      const date = new Date(iso);
      if (isNaN(date.getTime())) return String(iso).slice(11, 19);
      const pad = (value) => String(value).padStart(2, "0");
      return pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds());
    }

    function launchLabel(launchId) {
      const launch = launchesById[launchId];
      const time = launch ? clockTime(launch.startedAt) : "";
      const pid = launch ? launch.pid : null;
      const parts = ["App launch"];
      if (time) parts.push(time);
      if (pid != null) parts.push("pid " + pid);
      return parts.join(" · ");
    }

    function appendLaunchDivider(list, launchId, collapsedSet, rerender, onContextMenu) {
      const key = String(launchId);
      const isCollapsed = collapsedSet.has(key);
      const li = document.createElement("li");
      li.className = "launch-divider" + (isCollapsed ? " collapsed" : "");
      li.setAttribute("role", "button");
      li.setAttribute("tabindex", "0");
      li.setAttribute("aria-expanded", isCollapsed ? "false" : "true");
      const chevron = document.createElement("span");
      chevron.className = "launch-chevron";
      chevron.textContent = isCollapsed ? "▸" : "▾";
      const label = document.createElement("span");
      label.className = "launch-label";
      label.textContent = launchLabel(launchId);
      li.append(chevron, label);
      const toggle = () => {
        if (collapsedSet.has(key)) collapsedSet.delete(key);
        else collapsedSet.add(key);
        rerender();
      };
      li.addEventListener("click", toggle);
      li.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          toggle();
        }
      });
      if (onContextMenu) {
        li.addEventListener("contextmenu", (event) => {
          event.preventDefault();
          onContextMenu(event.clientX, event.clientY, launchId);
        });
      }
      list.appendChild(li);
      return isCollapsed;
    }

    function escapeHTML(value) {
      return String(value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
    }

    // Lists rebuild their whole DOM on every poll, which resets scrollTop and yanks the view.
    // Capture the scroll position before the rebuild, then hand it to restoreScroll() after.
    const SCROLL_EDGE_SLOP = 24;
    function captureScroll(el) {
      return {
        top: el.scrollTop,
        height: el.scrollHeight,
        atTop: el.scrollTop <= SCROLL_EDGE_SLOP,
        atBottom: el.scrollHeight - el.scrollTop - el.clientHeight <= SCROLL_EDGE_SLOP
      };
    }
    // `liveEnd` marks the edge where new cells appear ("bottom", "top", or "none"). We follow that
    // edge only when the user was already parked there; otherwise we keep their position so a
    // background append never moves the scroll while they're reading.
    function restoreScroll(el, liveEnd, prev) {
      if (liveEnd === "top") {
        el.scrollTop = prev.atTop ? 0 : prev.top + (el.scrollHeight - prev.height);
      } else if (liveEnd === "bottom") {
        el.scrollTop = prev.atBottom ? el.scrollHeight : prev.top;
      } else {
        el.scrollTop = prev.top;
      }
    }

    // ---- Network ----

    let networkEvents = [];
    let mockRulesById = {};
    let mockRuleExpanded = false;
    let networkSelectedId = null;
    let networkTimer = null;

    // Include/exclude filter chips, kept per tab and persisted across reloads.
    const FILTER_CHIPS_KEY = "simtool.filterChips";
    const filterChipsByTab = { network: [], logs: [], state: [], ax: [], tests: [] };
    try {
      const stored = JSON.parse(localStorage.getItem(FILTER_CHIPS_KEY) || "{}");
      for (const tab of Object.keys(filterChipsByTab)) {
        const list = stored && Array.isArray(stored[tab]) ? stored[tab] : [];
        filterChipsByTab[tab] = list.filter((chip) =>
          chip && (chip.kind === "include" || chip.kind === "exclude")
          && typeof chip.term === "string" && chip.term.trim()
        ).map((chip) =>
          typeof chip.field === "string" && chip.field.trim()
            ? { kind: chip.kind, term: chip.term, field: chip.field }
            : { kind: chip.kind, term: chip.term }
        );
      }
    } catch (_) { /* malformed storage: start clean */ }

    function saveFilterChips() {
      try { localStorage.setItem(FILTER_CHIPS_KEY, JSON.stringify(filterChipsByTab)); } catch (_) {}
    }

    function rerenderActiveTab() {
      if (activeTab === "network") renderNetworkList();
      else if (activeTab === "logs") renderLogsList();
      else if (activeTab === "state") renderState();
      else if (activeTab === "ax") renderAxTree();
      else if (activeTab === "tests") renderTestsList();
    }

    // Adding a chip replaces any chip with the same field+term (either kind),
    // so an exclude flips an identical include instead of stacking next to it.
    function chipKey(field, term) {
      return (field || "") + ":" + term.toLowerCase();
    }

    function addFilterChip(kind, term, field) {
      const trimmed = term.trim();
      if (!trimmed) return;
      const key = chipKey(field, trimmed);
      const chips = filterChipsByTab[activeTab].filter((chip) => chipKey(chip.field, chip.term) !== key);
      chips.push(field ? { kind, term: trimmed, field } : { kind, term: trimmed });
      filterChipsByTab[activeTab] = chips;
      saveFilterChips();
      renderFilterChips();
      rerenderActiveTab();
    }

    function removeFilterChip(index) {
      filterChipsByTab[activeTab].splice(index, 1);
      saveFilterChips();
      renderFilterChips();
      rerenderActiveTab();
    }


    // "field:text" scopes a term to one field instead of the whole haystack.
    // Only fields from the allowed list count; anything else (say, an URL's
    // "https:") stays a plain substring term.
    function parseFieldTerm(text, allowedFields) {
      const colon = text.indexOf(":");
      if (colon > 0 && allowedFields) {
        const field = text.slice(0, colon).trim().toLowerCase();
        const term = text.slice(colon + 1).trim();
        if (term && allowedFields.includes(field)) return { field, term };
      }
      return { field: null, term: text };
    }

    function termMatches(term, field, hay, fields) {
      const needle = term.toLowerCase();
      if (field) return !!fields && (fields[field] || "").includes(needle);
      return hay.includes(needle);
    }

    // Exclude chips win over include chips; include chips are OR'd ("show only
    // these"); the live input text is an extra substring filter on top.
    // `fields` (per-entry lowercased field map) backs field-scoped terms; tabs
    // without it match everything against the haystack.
    function matchesFilters(hay, chips, query, fields, queryField) {
      for (const chip of chips) {
        if (chip.kind === "exclude" && termMatches(chip.term, chip.field, hay, fields)) return false;
      }
      const includes = chips.filter((chip) => chip.kind === "include");
      if (includes.length && !includes.some((chip) => termMatches(chip.term, chip.field, hay, fields))) return false;
      return !query || termMatches(query, queryField, hay, fields);
    }

    function renderFilterChips() {
      filterChips.innerHTML = "";
      filterChipsByTab[activeTab].forEach((chip, index) => {
        const el = document.createElement("span");
        el.className = "filter-chip " + chip.kind;
        const label = (chip.field ? chip.field + ":" : "") + chip.term;
        const term = document.createElement("span");
        term.className = "chip-term";
        term.textContent = (chip.kind === "exclude" ? "−" : "") + label;
        term.title = label;
        const x = document.createElement("button");
        x.type = "button";
        x.className = "filter-chip-x";
        x.textContent = "✕";
        x.title = "Remove filter";
        x.addEventListener("click", () => removeFilterChip(index));
        el.append(term, x);
        filterChips.appendChild(el);
      });
    }

    function summarizeRequest(event) {
      const request = event.request || {};
      if (event.protocol === "grpc") {
        return request.path || [request.grpcService, request.grpcMethod].filter(Boolean).join("/");
      }
      return [request.method, request.url || request.path].filter(Boolean).join(" ");
    }

    function requestPath(event) {
      const request = event.request || {};
      if (event.protocol === "grpc") {
        return request.path || [request.grpcService, request.grpcMethod].filter(Boolean).join("/");
      }
      return request.url || request.path || "";
    }

    // URL path without host/query for context-menu chips (gRPC: service/method).
    function chipPathForEvent(event) {
      const raw = requestPath(event);
      if (!raw) return "";
      if (event.protocol === "grpc") return raw;
      try { return new URL(raw, "http://localhost").pathname; } catch (_) { return raw; }
    }

    function lastPathSegment(rawPath) {
      if (!rawPath) return "";
      let path = String(rawPath);
      const cut = path.search(/[?#]/);
      if (cut >= 0) path = path.slice(0, cut);
      path = path.replace(/\/+$/, "");
      const segments = path.split("/").filter(Boolean);
      return segments.length ? segments[segments.length - 1] : path;
    }

    function summarizeRequestShort(event) {
      const last = lastPathSegment(requestPath(event));
      if (event.protocol === "grpc") return last || summarizeRequest(event);
      const method = (event.request || {}).method;
      return [method, last].filter(Boolean).join(" ") || summarizeRequest(event);
    }

    function summarizeStatus(event) {
      if (event.error) return "ERR";
      const response = event.response || {};
      if (event.protocol === "grpc") {
        return response.grpcStatusCode != null ? String(response.grpcStatusCode) : "—";
      }
      return response.statusCode != null ? String(response.statusCode) : "—";
    }

    // Full status incl. the gRPC message — kept out of the row's status cell (code only),
    // but used for the row tooltip and the search haystack so the message stays discoverable.
    function fullStatusText(event) {
      if (event.error) return "ERR";
      const response = event.response || {};
      if (event.protocol === "grpc") {
        return [response.grpcStatusCode, response.grpcStatusMessage].filter(Boolean).join(" ") || "—";
      }
      return response.statusCode != null ? String(response.statusCode) : "—";
    }

    function statusClass(event) {
      if (event.error) return "status-err";
      const response = event.response || {};
      if (event.protocol === "grpc") {
        if (response.grpcStatusCode == null) return "";
        return response.grpcStatusCode === "0" ? "status-ok" : "status-err";
      }
      const code = response.statusCode;
      if (code == null) return "";
      if (code >= 500) return "status-err";
      if (code >= 300) return "status-warn";
      return "status-ok";
    }

    function networkEventHaystack(event) {
      const request = event.request || {};
      return [summarizeRequest(event), fullStatusText(event), event.protocol, request.host]
        .filter(Boolean).join(" ").toLowerCase();
    }

    function filteredNetworkEvents() {
      const query = (filterByTab.network || "").trim().toLowerCase();
      const chips = filterChipsByTab.network;
      if (!query && !chips.length) return networkEvents;
      return networkEvents.filter((event) => matchesFilters(networkEventHaystack(event), chips, query));
    }

    function renderNetworkList() {
      const events = filteredNetworkEvents();
      const prevScroll = captureScroll(networkList);
      networkList.innerHTML = "";
      if (!events.length) {
        const empty = document.createElement("li");
        empty.className = "network-empty";
        empty.textContent = "no requests captured";
        networkList.appendChild(empty);
        return;
      }
      // Oldest-first, grouped by launch — mirrors the Logs tab so both lists read top-to-bottom
      // and newly captured requests append at the bottom.
      const ordered = events.slice().sort((a, b) =>
        ((a.launchId ?? -1) - (b.launchId ?? -1)) || String(a.timestamp || "").localeCompare(String(b.timestamp || ""))
      );
      const firstLaunch = ordered.find((event) => event.launchId != null);
      let lastLaunch;
      let launchCollapsed = false;
      if (firstLaunch) {
        launchCollapsed = appendLaunchDivider(networkList, firstLaunch.launchId, collapsedNetworkLaunches, renderNetworkList, showNetworkLaunchMenu);
        lastLaunch = firstLaunch.launchId;
      }
      for (const event of ordered) {
        const lid = event.launchId;
        if (lid != null && lid !== lastLaunch) {
          launchCollapsed = appendLaunchDivider(networkList, lid, collapsedNetworkLaunches, renderNetworkList, showNetworkLaunchMenu);
          lastLaunch = lid;
        }
        if (launchCollapsed) continue;
        const row = document.createElement("li");
        row.className = "network-row" + (event.id === networkSelectedId ? " selected" : "") + (event.mocked ? " mocked" : "");
        const time = document.createElement("span");
        time.className = "time";
        time.textContent = clockTime(event.timestamp);
        const req = document.createElement("span");
        req.className = "req";
        req.textContent = summarizeRequestShort(event);
        req.title = summarizeRequest(event);
        if (event.mocked) {
          const badge = document.createElement("span");
          badge.className = "mock-badge";
          badge.textContent = "🎭";
          badge.title = event.mockRuleId ? ("Mocked by " + event.mockRuleId) : "Mocked response";
          req.appendChild(badge);
        }
        const status = document.createElement("span");
        status.className = "status " + statusClass(event);
        status.textContent = summarizeStatus(event);
        status.title = fullStatusText(event);
        const dur = document.createElement("span");
        dur.className = "dur";
        dur.textContent = Math.round(event.durationMilliseconds) + "ms";
        row.append(time, req, status, dur);
        row.addEventListener("click", () => {
          if (hasTextSelection()) return;
          networkSelectedId = event.id;
          renderNetworkDetail(event);
          showDetailView("Network");
        });
        row.addEventListener("contextmenu", (domEvent) => {
          domEvent.preventDefault();
          const path = chipPathForEvent(event);
          if (!path) return;
          showNetworkMenu(domEvent.clientX, domEvent.clientY, path);
        });
        networkList.appendChild(row);
      }
      restoreScroll(networkList, "bottom", prevScroll);
    }

    function renderNetworkDetail(event) {
      const lines = [];
      const section = (title) => lines.push(`<h3>${escapeHTML(title)}</h3>`);
      const pre = (text, mocked) => lines.push(`<pre${mocked ? ' class="mock-value"' : ''}>${escapeHTML(text)}</pre>`);
      const kv = (entries, mocked) => {
        const pairs = Object.entries(entries || {});
        if (!pairs.length) return;
        const cells = pairs.map(([key, value]) =>
          `<span class="kv-key">${escapeHTML(key)}</span><span class="kv-val${mocked ? ' mock-value' : ''}">${escapeHTML(value)}</span>`
        ).join("");
        lines.push(`<div class="kv">${cells}</div>`);
      };

      section("Overview");
      pre([
        summarizeRequest(event),
        `${event.protocol} · ${Math.round(event.durationMilliseconds)}ms · ${summarizeStatus(event)}`,
        event.timestamp,
        event.appBundleID || ""
      ].filter(Boolean).join("\n"));
      if (event.mocked) {
        lines.push(`<div class="kv"><span class="kv-key">Mocked</span><span class="kv-val mock-value">${escapeHTML(event.mockRuleId || "yes")}</span></div>`);
        const rule = event.mockRuleId ? mockRulesById[event.mockRuleId] : null;
        if (rule) {
          lines.push(`<details class="mock-rule"${mockRuleExpanded ? " open" : ""}><summary>Mock rule</summary><pre class="mock-value">${escapeHTML(JSON.stringify(rule, null, 2))}</pre></details>`);
        } else if (event.mockRuleId) {
          lines.push(`<div class="kv"><span class="kv-key">Mock rule</span><span class="kv-val">(no longer active)</span></div>`);
        }
      }

      const request = event.request || {};
      section("Request");
      kv(event.protocol === "grpc" ? request.metadata : request.headers);
      if (request.bodyPreview) pre(request.bodyPreview);

      if (event.response) {
        const response = event.response;
        section("Response");
        const mocked = !!event.mocked;
        if (event.protocol === "grpc") {
          const status = [response.grpcStatusCode, response.grpcStatusMessage].filter((s) => s != null && s !== "").join(" · ");
          if (status) kv({ "gRPC status": status }, mocked);
        } else if (response.statusCode != null) {
          kv({ "Status": String(response.statusCode) }, mocked);
        }
        kv(event.protocol === "grpc" ? response.metadata : response.headers);
        if (response.bodyPreview) pre(response.bodyPreview, mocked);
        else if (mocked) pre("(mock returned no body)", mocked);
      }

      if (event.error) {
        section("Error");
        pre(event.error.message || "");
      }

      detailBody.innerHTML = lines.join("");
      const mockRuleEl = detailBody.querySelector("details.mock-rule");
      if (mockRuleEl) {
        mockRuleEl.addEventListener("toggle", () => { mockRuleExpanded = mockRuleEl.open; });
      }
    }

    async function loadNetwork() {
      try {
        await loadLaunches();
        const response = await api("/api/v1/network/events?limit=200");
        const payload = await response.json();
        networkEvents = payload.events || [];
        networkCount.textContent = networkEvents.length;
        try {
          const mockResponse = await api("/api/v1/mocks");
          const mockPayload = await mockResponse.json();
          const map = {};
          (mockPayload.rules || []).forEach((rule) => { map[rule.id] = rule; });
          mockRulesById = map;
        } catch (_) { /* keep last known mock rules */ }
        if (activeTab === "network") {
          if (inspectorView === "list") renderNetworkList();
          else if (networkSelectedId != null) {
            const selected = networkEvents.find((event) => event.id === networkSelectedId);
            if (selected) renderNetworkDetail(selected);
          }
        }
      } catch (_) { /* keep last good render */ }
    }

    function startNetworkPolling() {
      loadNetwork();
      if (!networkTimer) networkTimer = setInterval(loadNetwork, 1500);
    }

    function stopNetworkPolling() {
      if (networkTimer) { clearInterval(networkTimer); networkTimer = null; }
    }

    // ---- Logs ----

    let logsEntries = [];
    let logsCursor = null;
    let logsTimer = null;
    let logsCaptureStarted = false;
    let logsTargetApp = "";
    const LOGS_MAX = 2000;

    function logsSourceLabel(entry) {
      return entry.source === "stdout" ? "stdout" : "oslog";
    }

    const LOGS_ERROR_RE = /\b(fatal error|error|exception|fault|crash|failure)\b|❌/i;
    function isErrorEntry(entry) {
      const level = (entry.level || "").toLowerCase();
      if (level === "error" || level === "fault") return true;
      return LOGS_ERROR_RE.test(entry.message || "");
    }

    const LOGS_FILTER_FIELDS = ["message", "subsystem", "category", "process", "level"];

    function filteredLogs() {
      const query = (filterByTab.logs || "").trim().toLowerCase();
      const chips = filterChipsByTab.logs;
      const live = parseFieldTerm(query, LOGS_FILTER_FIELDS);
      return logsEntries.filter((entry) => {
        if (!query && !chips.length) return true;
        const fields = {
          message: (entry.message || "").toLowerCase(),
          subsystem: (entry.subsystem || "").toLowerCase(),
          category: (entry.category || "").toLowerCase(),
          process: (entry.process || "").toLowerCase(),
          level: (entry.level || "").toLowerCase()
        };
        const hay = [fields.message, fields.subsystem, fields.category, fields.process, fields.level]
          .filter(Boolean).join(" ");
        return matchesFilters(hay, chips, live.term, fields, live.field);
      });
    }

    function renderLogsList() {
      // Group by launch rather than by arrival order: entries can be attributed to an earlier
      // launch than their neighbors (crash summaries are ingested during the next launch), and
      // rendering them in arrival order would split that launch's section in two.
      const entries = filteredLogs().slice().sort((a, b) =>
        ((a.launchId ?? -1) - (b.launchId ?? -1)) || (a.sequence - b.sequence)
      );
      const prevScroll = captureScroll(logsList);
      logsList.innerHTML = "";
      if (!entries.length) {
        const empty = document.createElement("li");
        empty.className = "logs-empty";
        empty.textContent = "no log lines captured";
        logsList.appendChild(empty);
        return;
      }
      const firstLaunch = entries.find((entry) => entry.launchId != null);
      let lastLaunch;
      let launchCollapsed = false;
      if (firstLaunch) {
        launchCollapsed = appendLaunchDivider(logsList, firstLaunch.launchId, collapsedLogLaunches, renderLogsList, showLogsLaunchMenu);
        lastLaunch = firstLaunch.launchId;
      }
      for (const entry of entries) {
        const lid = entry.launchId;
        if (lid != null && lid !== lastLaunch) {
          launchCollapsed = appendLaunchDivider(logsList, lid, collapsedLogLaunches, renderLogsList, showLogsLaunchMenu);
          lastLaunch = lid;
        }
        if (launchCollapsed) continue;
        const row = document.createElement("li");
        row.className = "logs-row" + (isErrorEntry(entry) ? " logs-row-error" : "");
        const source = logsSourceLabel(entry);
        const time = document.createElement("span");
        time.className = "time logs-src-" + source;
        time.textContent = (entry.timestamp || "").slice(11, 19);
        time.title = source;
        row.appendChild(time);
        if (entry.level) {
          const lvl = document.createElement("span");
          lvl.className = "lvl logs-src-" + source;
          lvl.textContent = entry.level;
          row.appendChild(lvl);
        }
        const msg = document.createElement("span");
        msg.className = "msg";
        msg.textContent = entry.message || "";
        row.appendChild(msg);
        row.addEventListener("click", () => {
          if (hasTextSelection()) return;
          renderLogDetail(entry);
          showDetailView("Logs");
        });
        row.addEventListener("contextmenu", (domEvent) => {
          domEvent.preventDefault();
          showLogsMenu(domEvent.clientX, domEvent.clientY, entry);
        });
        logsList.appendChild(row);
      }
      restoreScroll(logsList, "bottom", prevScroll);
    }

    function renderLogDetail(entry) {
      const lines = [];
      lines.push(`<h3>Entry</h3>`);
      const fields = {
        level: entry.level,
        source: logsSourceLabel(entry),
        subsystem: entry.subsystem,
        category: entry.category,
        process: entry.process,
        time: entry.timestamp
      };
      const cells = Object.entries(fields)
        .filter(([, value]) => value)
        .map(([key, value]) => `<span class="kv-key">${escapeHTML(key)}</span><span class="kv-val">${escapeHTML(value)}</span>`)
        .join("");
      if (cells) lines.push(`<div class="kv">${cells}</div>`);
      lines.push(`<h3>Message</h3>`);
      lines.push(`<pre>${escapeHTML(entry.message || "")}</pre>`);
      detailBody.innerHTML = lines.join("");
    }

    async function startLogsCapture() {
      const app = (logsTargetApp || "").trim();
      // Capture only ever starts scoped to an app: an unscoped capture streams OSLog for the
      // entire simulator, which drowns the viewer in unrelated system noise.
      if (!app) {
        logsStatus.textContent = "no app attached";
        return;
      }
      logsEntries = [];
      logsCursor = null;
      logsList.innerHTML = "";
      // OSLog only: the target app logs via os_log/Logger, so stdout/print capture (which would
      // relaunch the app to attach its console) is never requested.
      const body = { app };
      try {
        await api("/api/v1/logs/capture", { method: "POST", body: JSON.stringify(body) });
        logsStatus.textContent = "capturing oslog";
        logsCaptureStarted = true;
      } catch (error) {
        logsStatus.textContent = `error: ${error.message}`;
      }
    }

    async function pollLogs() {
      try {
        await loadLaunches();
        const since = logsCursor == null ? "" : `&since=${logsCursor}`;
        const response = await api(`/api/v1/logs/capture?limit=500${since}`);
        const payload = await response.json();
        const entries = payload.entries || [];
        if (entries.length) {
          logsEntries = logsEntries.concat(entries);
          if (logsEntries.length > LOGS_MAX) logsEntries = logsEntries.slice(logsEntries.length - LOGS_MAX);
          if (activeTab === "logs" && inspectorView === "list") renderLogsList();
        }
        if (payload.cursor != null) logsCursor = payload.cursor;
        logsCount.textContent = logsEntries.length;
        const dropped = payload.droppedCount ? ` · ${payload.droppedCount} dropped` : "";
        logsStatus.textContent = `${logsEntries.length} lines${dropped}`;
      } catch (error) {
        logsStatus.textContent = `error: ${error.message}`;
      }
    }

    function startLogsPolling() {
      pollLogs();
      if (!logsTimer) logsTimer = setInterval(pollLogs, 1500);
    }

    function stopLogsPolling() {
      if (logsTimer) { clearInterval(logsTimer); logsTimer = null; }
    }

    // Ensure logs are being captured + drained while the Logs tab is in view.
    async function ensureLogs() {
      if (!logsCaptureStarted) await startLogsCapture();
      if (inspectorOpen && logsCaptureStarted) startLogsPolling();
    }

    // ---- Accessibility (AX) ----

    let axTree = null;            // { roots, nodeCount }
    let axNodesByKey = new Map(); // node.id -> node (augmented with _key/_parentKey/_depth)
    let axExpanded = new Set();   // expanded node keys
    let axSelectedKey = null;
    let axHoverKey = null;
    let axTimer = null;
    let axFetching = false;
    let axLastUpdated = 0;
    let axFilter = "";

    function axHasFrame(node) {
      const f = node.frame;
      return !!(f && f.width > 0 && f.height > 0);
    }

    function axNodeLabel(node) {
      return node.accessibilityIdentifier || node.label || node.title
          || node.value || node.role || node.type || "element";
    }

    function axNodeSecondary(node) {
      return [node.role, node.type].filter(Boolean).join(" · ");
    }

    // Screen reference = the largest-area ROOT frame (the AXApplication, in points).
    // Only roots are considered: some deep container groups report their frame in
    // device pixels (e.g. 1206x2622 = 3x), which would otherwise hijack the reference
    // and squash every real (point-space) element into a corner.
    function axScreenFrame() {
      if (!axTree) return null;
      let best = null, bestArea = 0;
      for (const root of (axTree.roots || [])) {
        const f = root.frame;
        if (!f || !f.width || !f.height) continue;
        const area = f.width * f.height;
        if (area > bestArea) { bestArea = area; best = f; }
      }
      return best;
    }

    function axIndex(tree) {
      const byKey = new Map();
      const walk = (node, parentKey, depth) => {
        node._key = node.id;
        node._parentKey = parentKey;
        node._depth = depth;
        byKey.set(node.id, node);
        for (const child of node.children || []) walk(child, node.id, depth + 1);
      };
      for (const root of (tree.roots || [])) walk(root, null, 0);
      axNodesByKey = byKey;
    }

    function axHaystack(node) {
      return [node.accessibilityIdentifier, node.label, node.value, node.title, node.role, node.roleDescription, node.type]
        .filter(Boolean).join(" ").toLowerCase();
    }

    function axRow(node, expanded) {
      const hasChildren = (node.children || []).length > 0;
      const row = document.createElement("div");
      row.className = "ax-row" + (node._key === axSelectedKey ? " selected" : "");
      row.style.paddingLeft = (8 + node._depth * 14) + "px";
      row.dataset.key = node._key;

      const chevron = document.createElement("span");
      chevron.className = "ax-chevron";
      chevron.textContent = hasChildren ? (expanded ? "▾" : "▸") : "";
      if (hasChildren) {
        chevron.addEventListener("click", (event) => {
          event.stopPropagation();
          if (axExpanded.has(node._key)) axExpanded.delete(node._key);
          else axExpanded.add(node._key);
          renderAxTree();
        });
      }

      const primary = document.createElement("span");
      primary.className = "ax-label";
      primary.textContent = axNodeLabel(node);
      row.append(chevron, primary);

      // Show the human-readable label when it isn't already the primary text, so
      // identifier-named or role-only rows still say what the element actually is.
      const labelText = (node.label && node.label.trim()) ? node.label : "";
      if (labelText && labelText !== primary.textContent) {
        const human = document.createElement("span");
        human.className = "ax-text";
        human.textContent = '"' + labelText + '"';
        row.append(human);
      }

      const secondary = document.createElement("span");
      secondary.className = "ax-secondary";
      secondary.textContent = axNodeSecondary(node);
      row.append(secondary);
      row.addEventListener("click", () => selectAxNode(node._key, false));
      row.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        selectAxNode(node._key, false);
        showAxMenu(event.clientX, event.clientY, node);
      });
      row.addEventListener("mouseenter", () => { axHoverKey = node._key; renderAxOverlay(); });
      row.addEventListener("mouseleave", () => { if (axHoverKey === node._key) { axHoverKey = null; renderAxOverlay(); } });
      return row;
    }

    function renderAxTree() {
      if (!axTree) { axTreeEl.innerHTML = '<span class="ax-empty">no accessibility tree</span>'; return; }
      const q = axFilter.trim().toLowerCase();
      const chips = filterChipsByTab.ax;
      let showKeys = null;
      if (q || chips.length) {
        showKeys = new Set();
        for (const node of axNodesByKey.values()) {
          if (!matchesFilters(axHaystack(node), chips, q)) continue;
          showKeys.add(node._key);
          let pk = node._parentKey;
          while (pk != null && !showKeys.has(pk)) {
            showKeys.add(pk);
            const parent = axNodesByKey.get(pk);
            pk = parent ? parent._parentKey : null;
          }
        }
      }
      const rows = [];
      const walk = (node) => {
        if (showKeys && !showKeys.has(node._key)) return;
        const expanded = showKeys ? true : axExpanded.has(node._key);
        rows.push(axRow(node, expanded));
        if (expanded) for (const child of (node.children || [])) walk(child);
      };
      for (const root of (axTree.roots || [])) walk(root);
      axTreeEl.innerHTML = "";
      if (!rows.length) { axTreeEl.innerHTML = '<span class="ax-empty">no matches</span>'; return; }
      for (const row of rows) axTreeEl.appendChild(row);
    }

    function updateAxStatus() {
      const count = axTree ? axTree.nodeCount : 0;
      axStatusEl.textContent = axTree ? `${count} nodes · updated just now` : "—";
    }

    async function loadAxTree() {
      if (axFetching) return;
      axFetching = true;
      try {
        const response = await api("/api/v1/ax/tree?raw=1");
        const payload = await response.json();
        axTree = payload;
        axIndex(payload);
        axLastUpdated = performance.now();
        if (activeTab === "ax" && inspectorOpen) {
          renderAxTree();
          renderAxSelected();
          renderAxOverlay();
          updateAxStatus();
        }
      } catch (error) {
        axStatusEl.textContent = `error: ${error.message}`;
      } finally {
        axFetching = false;
      }
    }

    function startAxPolling() {
      loadAxTree();
      if (!axTimer) axTimer = setInterval(loadAxTree, 2000);
    }

    function stopAxPolling() {
      if (axTimer) { clearInterval(axTimer); axTimer = null; }
    }

    // Frame points -> percentage box within .surface (percentages auto-track resize).
    function axFrameToBox(frame, screen) {
      return {
        left: ((frame.x - screen.x) / screen.width) * 100,
        top: ((frame.y - screen.y) / screen.height) * 100,
        width: (frame.width / screen.width) * 100,
        height: (frame.height / screen.height) * 100
      };
    }

    function renderAxOverlay() {
      if (!axOverlay) return;
      const show = inspectorOpen && activeTab === "ax" && !!axTree;
      axOverlay.hidden = !show;
      if (!show) { axOverlay.innerHTML = ""; return; }
      const screen = axScreenFrame();
      axOverlay.innerHTML = "";
      if (!screen || !screen.width || !screen.height) return;
      for (const node of axNodesByKey.values()) {
        if (!axHasFrame(node)) continue;
        const box = axFrameToBox(node.frame, screen);
        // Skip frames that overflow the point-space screen — these are the
        // pixel-scaled container groups, not real on-screen elements.
        if (box.width > 105 || box.height > 105) continue;
        const el = document.createElement("div");
        let cls = "ax-box";
        if (node._key === axSelectedKey) cls += " selected";
        else if (node._key === axHoverKey) cls += " hover";
        el.className = cls;
        el.style.left = box.left + "%";
        el.style.top = box.top + "%";
        el.style.width = box.width + "%";
        el.style.height = box.height + "%";
        axOverlay.appendChild(el);
      }
    }

    function selectAxNode(key, fromCanvas) {
      axSelectedKey = key;
      if (fromCanvas) {
        let node = axNodesByKey.get(key);
        let pk = node ? node._parentKey : null;
        while (pk != null) {
          axExpanded.add(pk);
          const parent = axNodesByKey.get(pk);
          pk = parent ? parent._parentKey : null;
        }
      }
      renderAxTree();
      renderAxSelected();
      renderAxOverlay();
      if (fromCanvas) {
        const row = axTreeEl.querySelector(".ax-row.selected");
        if (row) row.scrollIntoView({ block: "nearest" });
      }
    }

    // Canvas click -> deepest (smallest-area) framed node containing the point.
    function axHitTest(clientX, clientY) {
      const rect = surface.getBoundingClientRect();
      if (!rect.width || !rect.height) return null;
      const screen = axScreenFrame();
      if (!screen) return null;
      const px = screen.x + ((clientX - rect.left) / rect.width) * screen.width;
      const py = screen.y + ((clientY - rect.top) / rect.height) * screen.height;
      let best = null, bestArea = Infinity;
      for (const node of axNodesByKey.values()) {
        const f = node.frame;
        if (!axHasFrame(node)) continue;
        if (px >= f.x && px <= f.x + f.width && py >= f.y && py <= f.y + f.height) {
          const area = f.width * f.height;
          // <= so that among coincident frames (e.g. Application and its Window
          // both cover the screen) the deepest, last-walked node wins.
          if (area <= bestArea) { bestArea = area; best = node; }
        }
      }
      return best;
    }

    function axSelectMode() {
      return inspectorOpen && activeTab === "ax";
    }

    function axUpdateCanvasMode() {
      canvas.classList.toggle("ax-pick", axSelectMode());
    }

    function axAncestorPath(node) {
      const path = [];
      let pk = node._parentKey;
      while (pk != null) {
        const parent = axNodesByKey.get(pk);
        if (!parent) break;
        path.unshift(axNodeLabel(parent));
        pk = parent._parentKey;
      }
      return path;
    }

    function axCopyPayload(node) {
      return {
        accessibilityIdentifier: node.accessibilityIdentifier ?? null,
        label: node.label ?? null,
        value: node.value ?? null,
        title: node.title ?? null,
        role: node.role ?? null,
        roleDescription: node.roleDescription ?? null,
        type: node.type ?? null,
        enabled: node.enabled ?? null,
        pid: node.pid ?? null,
        frame: node.frame ?? null,
        ancestorPath: axAncestorPath(node),
        raw: node.raw ?? null
      };
    }

    function renderAxSelected() {
      const node = axSelectedKey ? axNodesByKey.get(axSelectedKey) : null;
      if (!node) { axSelectedBar.hidden = true; return; }
      axSelectedBar.hidden = false;
      axSelectedLabel.textContent = axNodeLabel(node);
    }

    async function axWriteClipboard(text) {
      try {
        await navigator.clipboard.writeText(text);
      } catch (_) {
        const area = document.createElement("textarea");
        area.value = text;
        document.body.appendChild(area);
        area.select();
        try { document.execCommand("copy"); } catch (_) {}
        document.body.removeChild(area);
      }
    }

    function axFlashCopied() {
      axCopyButton.textContent = "Copied ✓";
      setTimeout(() => { axCopyButton.textContent = "Copy JSON"; }, 1200);
    }

    // Copy one node's full JSON. Used by the Copy button and by right-click
    // (contextmenu) on a tree row or on the device screen.
    async function copyAxNode(node) {
      if (!node) return;
      await axWriteClipboard(JSON.stringify(axCopyPayload(node), null, 2));
      axFlashCopied();
    }

    function copyAxSelected() {
      copyAxNode(axSelectedKey ? axNodesByKey.get(axSelectedKey) : null);
    }

    // Right-click context menu with a single "Copy element" action.
    let axMenuNode = null;
    function showAxMenu(x, y, node) {
      axMenuNode = node;
      axMenu.hidden = false;
      const rect = axMenu.getBoundingClientRect();
      const maxX = window.innerWidth - rect.width - 6;
      const maxY = window.innerHeight - rect.height - 6;
      axMenu.style.left = Math.max(6, Math.min(x, maxX)) + "px";
      axMenu.style.top = Math.max(6, Math.min(y, maxY)) + "px";
    }
    function hideAxMenu() {
      axMenu.hidden = true;
      axMenuNode = null;
    }

    // Right-click menu on network rows: include/exclude the request path.
    let networkMenuPath = "";
    function showNetworkMenu(x, y, path) {
      networkMenuPath = path;
      const short = path.length > 42 ? "…" + path.slice(-41) : path;
      networkMenuExclude.textContent = "Exclude '" + short + "'";
      networkMenuInclude.textContent = "Include '" + short + "'";
      networkMenu.hidden = false;
      const rect = networkMenu.getBoundingClientRect();
      networkMenu.style.left = Math.max(6, Math.min(x, window.innerWidth - rect.width - 6)) + "px";
      networkMenu.style.top = Math.max(6, Math.min(y, window.innerHeight - rect.height - 6)) + "px";
    }
    function hideNetworkMenu() {
      networkMenu.hidden = true;
      networkMenuPath = "";
    }

    // Right-click menu on a network launch divider: purge that launch's requests server-side.
    let networkLaunchMenuId = null;
    function showNetworkLaunchMenu(x, y, launchId) {
      networkLaunchMenuId = launchId;
      networkLaunchMenu.hidden = false;
      const rect = networkLaunchMenu.getBoundingClientRect();
      networkLaunchMenu.style.left = Math.max(6, Math.min(x, window.innerWidth - rect.width - 6)) + "px";
      networkLaunchMenu.style.top = Math.max(6, Math.min(y, window.innerHeight - rect.height - 6)) + "px";
    }
    function hideNetworkLaunchMenu() {
      networkLaunchMenu.hidden = true;
      networkLaunchMenuId = null;
    }

    // Mouseup after dragging out a selection also fires click; rows must not
    // open their detail view (and destroy the selection) in that case.
    function hasTextSelection() {
      const selection = window.getSelection();
      return !!selection && !selection.isCollapsed;
    }

    // Right-click menu on log rows: copy the full entry, or — when text is
    // selected — copy/include/exclude the selected text. The selection is
    // captured at open time: clicking a menu item may collapse it.
    let logsMenuEntry = null;
    let logsMenuSelection = "";
    function showLogsMenu(x, y, entry) {
      logsMenuEntry = entry;
      logsMenuSelection = hasTextSelection() ? window.getSelection().toString() : "";
      const selected = !!logsMenuSelection.trim();
      logsMenuCopy.hidden = selected;
      logsMenuCopySel.hidden = !selected;
      logsMenuIncludeSel.hidden = !selected;
      logsMenuExcludeSel.hidden = !selected;
      logsMenu.hidden = false;
      const rect = logsMenu.getBoundingClientRect();
      logsMenu.style.left = Math.max(6, Math.min(x, window.innerWidth - rect.width - 6)) + "px";
      logsMenu.style.top = Math.max(6, Math.min(y, window.innerHeight - rect.height - 6)) + "px";
    }
    function hideLogsMenu() {
      logsMenu.hidden = true;
      logsMenuEntry = null;
      logsMenuSelection = "";
    }

    // Right-click menu on a logs launch divider: purge that launch's entries server-side.
    let logsLaunchMenuId = null;
    function showLogsLaunchMenu(x, y, launchId) {
      logsLaunchMenuId = launchId;
      logsLaunchMenu.hidden = false;
      const rect = logsLaunchMenu.getBoundingClientRect();
      logsLaunchMenu.style.left = Math.max(6, Math.min(x, window.innerWidth - rect.width - 6)) + "px";
      logsLaunchMenu.style.top = Math.max(6, Math.min(y, window.innerHeight - rect.height - 6)) + "px";
    }
    function hideLogsLaunchMenu() {
      logsLaunchMenu.hidden = true;
      logsLaunchMenuId = null;
    }

    // Right-click menu on test session rows: delete the session's artifacts.
    let testsMenuSessionId = null;
    function showTestsMenu(x, y, session) {
      testsMenuSessionId = session.id;
      testsMenu.hidden = false;
      const rect = testsMenu.getBoundingClientRect();
      testsMenu.style.left = Math.max(6, Math.min(x, window.innerWidth - rect.width - 6)) + "px";
      testsMenu.style.top = Math.max(6, Math.min(y, window.innerHeight - rect.height - 6)) + "px";
    }
    function hideTestsMenu() {
      testsMenu.hidden = true;
      testsMenuSessionId = null;
    }

    function logEntryText(entry) {
      const head = [entry.timestamp, entry.level, entry.subsystem].filter(Boolean).join(" ");
      const message = entry.message || "";
      return head ? head + ": " + message : message;
    }

    function showFilterHelp() {
      // Tab-specific lines only show on their tab; untagged lines always do.
      for (const line of filterHelpPop.querySelectorAll("[data-tab]")) {
        line.hidden = line.dataset.tab !== activeTab;
      }
      filterHelpPop.hidden = false;
      const button = filterHelp.getBoundingClientRect();
      const rect = filterHelpPop.getBoundingClientRect();
      filterHelpPop.style.left = Math.max(6, Math.min(button.left, window.innerWidth - rect.width - 6)) + "px";
      filterHelpPop.style.top = (button.bottom + 6) + "px";
    }
    function hideFilterHelp() { filterHelpPop.hidden = true; }

    // ---- State inspector: live model snapshots pushed by the app under test ----

    let stateCursor = null;
    let statePollTimer = null;
    const stateLatest = new Map();   // modelId -> latest event
    const stateChanges = [];          // { event, diffs }, oldest first
    const STATE_HISTORY_LIMIT = 300;

    function startStatePolling() {
      if (statePollTimer) return;
      pollStateEvents();
      statePollTimer = setInterval(pollStateEvents, 1000);
    }

    function stopStatePolling() {
      if (!statePollTimer) return;
      clearInterval(statePollTimer);
      statePollTimer = null;
    }

    async function pollStateEvents() {
      try {
        const since = stateCursor == null ? "" : "&since=" + stateCursor;
        const res = await fetch("/api/v1/state/events?limit=500" + since);
        if (!res.ok) return;
        const payload = await res.json();
        if (!payload.events || !payload.events.length) return;
        for (const event of payload.events) {
          const prev = stateLatest.get(event.modelId);
          const diffs = diffStateValues(prev ? prev.snapshot : undefined, event.snapshot, "", []);
          if (prev || event.deallocated) {
            stateChanges.push({ event, diffs });
            if (stateChanges.length > STATE_HISTORY_LIMIT) stateChanges.shift();
          }
          // A deallocation event carries no snapshot; keep the last known state
          // so the greyed-out card still shows what the model looked like.
          const stored = event.deallocated && prev ? { ...event, snapshot: prev.snapshot } : event;
          stateLatest.set(event.modelId, stored);
        }
        stateCursor = payload.nextCursor;
        stateCountEl.textContent = String(stateLatest.size);
        if (activeTab === "state" && inspectorOpen) renderState();
      } catch (_) { /* server may be restarting; next poll retries */ }
    }

    // Nested models that are themselves tracked carry this marker in their
    // snapshot object; the viewer folds their standalone history into the
    // parent's diff and never renders the key itself.
    const MODEL_ID_KEY = "$modelId";

    // childId -> parentId for models embedded (expanded) inside another live
    // tracked model's snapshot. Recomputed per render from stateLatest, so a
    // child resurfaces on its own once the parent deallocates.
    function embeddedModelIds() {
      const embedded = new Map();
      for (const [id, event] of stateLatest) {
        if (event.deallocated) continue;
        collectEmbedded(event.snapshot, id, embedded);
      }
      return embedded;
    }

    function collectEmbedded(value, ownerId, out) {
      if (!value || typeof value !== "object") return;
      if (Array.isArray(value)) {
        for (const item of value) collectEmbedded(item, ownerId, out);
        return;
      }
      const marker = value[MODEL_ID_KEY];
      if (typeof marker === "string" && marker !== ownerId) out.set(marker, ownerId);
      for (const key of Object.keys(value)) {
        if (key !== MODEL_ID_KEY) collectEmbedded(value[key], ownerId, out);
      }
    }

    function diffStateValues(prev, next, path, out) {
      if (JSON.stringify(prev) === JSON.stringify(next)) return out;
      const isPlainObject = (v) => v && typeof v === "object" && !Array.isArray(v);
      if (isPlainObject(prev) && isPlainObject(next)) {
        for (const key of new Set([...Object.keys(prev), ...Object.keys(next)])) {
          if (key === MODEL_ID_KEY) continue;
          diffStateValues(prev[key], next[key], path ? path + "." + key : key, out);
        }
        return out;
      }
      out.push({ path, before: prev, after: next });
      return out;
    }

    function renderStateTree(value, container) {
      const appendBranch = (labelText, child) => {
        const details = document.createElement("details");
        details.open = true;
        const summary = document.createElement("summary");
        summary.textContent = labelText + (Array.isArray(child) ? " [" + child.length + "]" : "");
        details.appendChild(summary);
        const inner = document.createElement("div");
        inner.className = "state-tree";
        renderStateTree(child, inner);
        details.appendChild(inner);
        container.appendChild(details);
      };
      const appendLeaf = (labelText, child) => {
        const row = document.createElement("div");
        row.textContent = labelText + ": " + JSON.stringify(child);
        container.appendChild(row);
      };
      if (value && typeof value === "object" && !Array.isArray(value)) {
        for (const key of Object.keys(value).sort()) {
          if (key === MODEL_ID_KEY) continue;
          const child = value[key];
          if (child && typeof child === "object") appendBranch(key, child);
          else appendLeaf(key, child);
        }
      } else if (Array.isArray(value)) {
        value.forEach((item, index) => {
          if (item && typeof item === "object") appendBranch("[" + index + "]", item);
          else appendLeaf("[" + index + "]", item);
        });
      } else {
        const row = document.createElement("div");
        row.textContent = JSON.stringify(value);
        container.appendChild(row);
      }
    }

    function renderState() {
      const query = (filterByTab.state || "").trim().toLowerCase();
      const chips = filterChipsByTab.state;
      const prevScroll = captureScroll(statePane);
      stateModelsEl.textContent = "";
      for (const id of [...stateLatest.keys()].sort()) {
        if (!matchesFilters(id.toLowerCase(), chips, query)) continue;
        const event = stateLatest.get(id);
        const card = document.createElement("details");
        card.className = "state-model" + (event.deallocated ? " state-dead" : "");
        card.open = true;
        const summary = document.createElement("summary");
        summary.textContent = id + (event.deallocated ? " (deallocated)" : "");
        card.appendChild(summary);
        const tree = document.createElement("div");
        tree.className = "state-tree";
        renderStateTree(event.snapshot, tree);
        card.appendChild(tree);
        stateModelsEl.appendChild(card);
      }
      stateHistoryEl.textContent = "";
      const embedded = embeddedModelIds();
      for (let i = stateChanges.length - 1; i >= 0; i--) {
        const { event, diffs } = stateChanges[i];
        // The parent's history entry already shows this change as a nested diff.
        if (embedded.has(event.modelId)) continue;
        if (!matchesFilters(event.modelId.toLowerCase(), chips, query)) continue;
        const block = document.createElement("div");
        block.className = "state-change";
        const title = document.createElement("div");
        title.className = "state-change-title";
        title.textContent = event.modelId + " · seq " + event.seq + " · "
          + new Date(event.timestamp * 1000).toLocaleTimeString()
          + (event.deallocated ? " · deallocated" : "");
        block.appendChild(title);
        for (const diff of diffs) {
          const minus = document.createElement("div");
          minus.className = "state-diff-minus";
          minus.textContent = "- " + diff.path + ": " + JSON.stringify(diff.before);
          block.appendChild(minus);
          const plus = document.createElement("div");
          plus.className = "state-diff-plus";
          plus.textContent = "+ " + diff.path + ": " + JSON.stringify(diff.after);
          block.appendChild(plus);
        }
        stateHistoryEl.appendChild(block);
      }
      restoreScroll(statePane, "top", prevScroll);
    }

    // ---- Tests ----

    let testsSessions = [];
    let testsTimer = null;
    let selectedTestId = null;
    let testsLastPayload = "";

    const TEST_STATUS_LABEL = { running: "● running", passed: "✓ passed", failed: "✗ failed", interrupted: "◌ interrupted" };

    async function loadTests() {
      try {
        const response = await fetch("/api/v1/tests");
        if (!response.ok) return;
        const payload = await response.json();
        const previous = testsSessions;
        const serialized = JSON.stringify(payload.sessions || []);
        if (serialized === testsLastPayload) return;
        testsLastPayload = serialized;
        testsSessions = payload.sessions || [];
        if (!selectedTestId && testsSessions.length) selectedTestId = testsSessions[0].id;
        if (selectedTestId && !testsSessions.some((s) => s.id === selectedTestId)) {
          selectedTestId = testsSessions.length ? testsSessions[0].id : null;
          if (playbackTestId && !testsSessions.some((s) => s.id === playbackTestId)) showLiveStream();
        }
        maybeAutoSwitchPlayback(previous);
        renderTestsList();
        renderTestTimeline();
      } catch (_) {}
    }

    let playbackTestId = null;

    // While a session is running the live stream stays: the agent is driving
    // the simulator right now. The moment the watched session finishes, swap
    // to its recording.
    function maybeAutoSwitchPlayback(previousSessions) {
      const selected = testsSessions.find((s) => s.id === selectedTestId);
      const before = previousSessions.find((s) => s.id === selectedTestId);
      if (selected && before && before.status === "running" && selected.status !== "running") {
        showTestVideo(selected);
      }
    }

    function showTestVideo(session) {
      if (!session || session.status === "running" || session.videoError) return;
      if (playbackTestId === session.id && !testPlayback.hidden) return;
      playbackTestId = session.id;
      testVideo.src = "/api/v1/tests/" + encodeURIComponent(session.id) + "/video";
      testPlayback.hidden = false;
      testVideoNote.hidden = true;
    }

    function showLiveStream() {
      playbackTestId = null;
      testPlayback.hidden = true;
      testVideo.pause();
      testVideo.removeAttribute("src");
      testVideo.load();
      testVideoNote.hidden = true;
    }

    // The current step follows the playhead.
    testVideo.addEventListener("timeupdate", () => {
      updateTestControls();
      const session = testsSessions.find((s) => s.id === playbackTestId);
      if (!session || activeTab !== "tests") return;
      let currentIndex = -1;
      (session.entries || []).forEach((entry, index) => {
        if (entry.kind === "step" && entryOffsetSeconds(session, entry) <= testVideo.currentTime + 0.25) {
          currentIndex = index;
        }
      });
      testsTimelineEl.querySelectorAll(".tests-step").forEach((row) => {
        row.classList.toggle("current", Number(row.dataset.index) === currentIndex);
      });
    });

    // Unfinalized/missing mp4 (hard-killed server): keep the timeline, flag the video.
    testVideo.addEventListener("error", () => {
      if (testPlayback.hidden) return;
      testVideoNote.hidden = false;
    });

    testBackLive.addEventListener("click", showLiveStream);

    const testPlayPause = $("testPlayPause");
    const testSeek = $("testSeek");
    const testTime = $("testTime");
    let testSeekDragging = false;

    function toggleTestPlayback() {
      if (testVideo.paused) testVideo.play().catch(() => {});
      else testVideo.pause();
    }

    function updateTestControls() {
      const duration = isFinite(testVideo.duration) ? testVideo.duration : 0;
      testPlayPause.textContent = testVideo.paused ? "▶" : "⏸";
      testTime.textContent = formatOffset(testVideo.currentTime) + " / " + formatOffset(duration);
      if (!testSeekDragging) {
        testSeek.value = duration ? String(Math.round(testVideo.currentTime / duration * 1000)) : "0";
      }
    }

    testPlayPause.addEventListener("click", toggleTestPlayback);
    // The video element itself never receives clicks in Orca's embedded
    // browser; in regular browsers this adds click-to-toggle for free.
    testVideo.addEventListener("click", toggleTestPlayback);
    testSeek.addEventListener("pointerdown", () => { testSeekDragging = true; });
    testSeek.addEventListener("pointerup", () => { testSeekDragging = false; });
    testSeek.addEventListener("input", () => {
      const duration = isFinite(testVideo.duration) ? testVideo.duration : 0;
      if (!duration) return;
      testVideo.currentTime = Number(testSeek.value) / 1000 * duration;
    });
    for (const eventName of ["play", "pause", "loadedmetadata", "ended", "seeked"]) {
      testVideo.addEventListener(eventName, updateTestControls);
    }

    let flowsList = [];
    let flowRunStatus = null;
    let flowsLastPayload = "";

    async function loadFlows() {
      try {
        const [flowsResponse, runResponse] = await Promise.all([
          fetch("/api/v1/flows"),
          fetch("/api/v1/flows/run"),
        ]);
        if (!flowsResponse.ok || !runResponse.ok) return;
        const flowsPayload = await flowsResponse.json();
        const runPayload = await runResponse.json();
        const serialized = JSON.stringify([flowsPayload.flows || [], runPayload]);
        if (serialized === flowsLastPayload) return;
        flowsLastPayload = serialized;
        flowsList = flowsPayload.flows || [];
        const previousRun = flowRunStatus;
        flowRunStatus = runPayload;
        // Follow the run: select its session so the timeline streams the steps
        // live; when it finishes, the regular auto-switch plays the recording.
        if (runPayload.active && runPayload.sessionId &&
            (!previousRun || previousRun.sessionId !== runPayload.sessionId)) {
          selectedTestId = runPayload.sessionId;
          showLiveStream();
        }
        renderFlowsList();
      } catch (_) {}
    }

    async function runFlow(file) {
      try {
        const response = await fetch("/api/v1/flows/run", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ file }),
        });
        const payload = await response.json().catch(() => null);
        if (response.ok && payload) {
          flowRunStatus = payload;
          flowsLastPayload = "";
          renderFlowsList();
          loadTests();
        } else if (payload && payload.error) {
          flowRunStatus = { active: false, file, status: "failed", error: payload.error, completedSteps: 0, totalSteps: 0 };
          renderFlowsList();
        }
      } catch (_) {}
    }

    function renderFlowsList() {
      if (activeTab !== "tests") return;
      const prevScroll = captureScroll(testsFlowsEl);
      testsFlowsEl.innerHTML = "";
      const header = document.createElement("div");
      header.className = "tests-section-header";
      header.textContent = "Flows · .simtool/flows";
      testsFlowsEl.appendChild(header);
      if (!flowsList.length) {
        const empty = document.createElement("div");
        empty.className = "tests-empty";
        empty.textContent = "no flows yet — add a YAML flow to .simtool/flows";
        testsFlowsEl.appendChild(empty);
        return;
      }
      const busy = Boolean(flowRunStatus && flowRunStatus.active);
      for (const flow of flowsList) {
        const row = document.createElement("div");
        row.className = "flows-row";
        const title = document.createElement("span");
        title.className = "flows-title";
        title.textContent = flow.name || flow.file;
        title.title = flow.file;
        if (flow.description) {
          const desc = document.createElement("div");
          desc.className = "flows-desc";
          desc.textContent = flow.description;
          title.appendChild(desc);
        }
        const meta = document.createElement("span");
        meta.className = "flows-meta";
        const isCurrent = flowRunStatus && flowRunStatus.file === flow.file;
        if (flow.parseError) {
          meta.textContent = "parse error";
          meta.classList.add("flows-error");
          meta.title = flow.parseError;
        } else if (isCurrent && flowRunStatus.active) {
          meta.textContent = "● " + flowRunStatus.completedSteps + "/" + flowRunStatus.totalSteps;
          meta.classList.add("tests-status-running");
        } else if (isCurrent && flowRunStatus.status) {
          meta.textContent = flowRunStatus.status === "passed" ? "✓ passed" : "✗ failed";
          meta.classList.add(flowRunStatus.status === "passed" ? "tests-status-passed" : "tests-status-failed");
          if (flowRunStatus.error) meta.title = flowRunStatus.error;
        } else {
          meta.textContent = flow.stepCount + " steps";
        }
        const runButton = document.createElement("button");
        runButton.className = "flows-run";
        runButton.type = "button";
        runButton.textContent = "Run";
        runButton.disabled = busy || Boolean(flow.parseError);
        runButton.addEventListener("click", () => runFlow(flow.file));
        row.append(title, meta, runButton);
        testsFlowsEl.appendChild(row);
      }
      restoreScroll(testsFlowsEl, "none", prevScroll);
    }

    function startTestsPolling() {
      loadTests();
      loadFlows();
      if (!testsTimer) testsTimer = setInterval(() => { loadTests(); loadFlows(); }, 1500);
    }

    function stopTestsPolling() {
      if (testsTimer) { clearInterval(testsTimer); testsTimer = null; }
    }

    function testSessionHaystack(session) {
      return [session.title, session.status, session.deviceName].join(" ").toLowerCase();
    }

    function filteredTestSessions() {
      const chips = filterChipsByTab.tests;
      const query = (filterByTab.tests || "").trim().toLowerCase();
      return testsSessions.filter((session) => matchesFilters(testSessionHaystack(session), chips, query, null, null));
    }

    function formatOffset(seconds) {
      if (!isFinite(seconds) || seconds < 0) seconds = 0;
      return Math.floor(seconds / 60) + ":" + String(Math.floor(seconds % 60)).padStart(2, "0");
    }

    // Video offset of an entry. The raw offset is the wall-clock span since the
    // recorder started (at − recordingStartedAt, falling back to startedAt), but
    // simctl's footage runs shorter than wall-clock — recorder startup/stop
    // latency plus frame-rate drift under load — so a fixed anchor drifts ahead
    // of the video and late steps can land past its end. When the real video
    // length is known, scale the wall-clock span onto it; a no-op when the
    // clocks agree.
    function entryOffsetSeconds(session, entry) {
      const base = Date.parse(session.recordingStartedAt || session.startedAt);
      const at = Date.parse(entry.at);
      if (!isFinite(base) || !isFinite(at)) return 0;
      const raw = Math.max(0, (at - base) / 1000);
      const dur = session.videoDurationSeconds;
      const end = Date.parse(session.endedAt || "");
      if (isFinite(dur) && dur > 0 && isFinite(end)) {
        const span = (end - base) / 1000;
        if (span > 0) return Math.min(dur, (raw / span) * dur);
      }
      return raw;
    }

    function sessionDurationSeconds(session) {
      const dur = session.videoDurationSeconds;
      if (isFinite(dur) && dur > 0) return dur;
      const base = Date.parse(session.recordingStartedAt || session.startedAt);
      const end = Date.parse(session.endedAt || "");
      return isFinite(base) && isFinite(end) ? Math.max(0, (end - base) / 1000) : 0;
    }

    function renderTestsList() {
      testsCountEl.textContent = String(testsSessions.length);
      if (activeTab !== "tests") return;
      const sessions = filteredTestSessions();
      const prevScroll = captureScroll(testsSessionsEl);
      testsSessionsEl.innerHTML = "";
      if (!sessions.length) {
        const empty = document.createElement("div");
        empty.className = "tests-empty";
        empty.textContent = testsSessions.length
          ? "no sessions match the filter"
          : "no test sessions yet — run a flow";
        testsSessionsEl.appendChild(empty);
        return;
      }
      for (const session of sessions) {
        const row = document.createElement("div");
        row.className = "tests-row" + (session.id === selectedTestId ? " selected" : "");
        const title = document.createElement("span");
        title.className = "tests-title";
        title.textContent = session.title;
        const meta = document.createElement("span");
        meta.className = "tests-meta tests-status-" + session.status;
        const duration = session.endedAt ? " · " + formatOffset(sessionDurationSeconds(session)) : "";
        const startedAt = new Date(session.startedAt);
        const startStamp = isNaN(startedAt.getTime()) ? "" :
          " · " + String(startedAt.getHours()).padStart(2, "0") + ":" + String(startedAt.getMinutes()).padStart(2, "0");
        meta.textContent = (TEST_STATUS_LABEL[session.status] || session.status) + duration + startStamp;
        row.append(title, meta);
        row.addEventListener("click", () => selectTestSession(session.id));
        row.addEventListener("contextmenu", (event) => {
          event.preventDefault();
          // The active recording is protected server-side; don't offer Delete.
          if (session.status === "running") return;
          showTestsMenu(event.clientX, event.clientY, session);
        });
        testsSessionsEl.appendChild(row);
      }
      restoreScroll(testsSessionsEl, "none", prevScroll);
    }

    function selectTestSession(id) {
      selectedTestId = id;
      renderTestsList();
      renderTestTimeline();
      const session = testsSessions.find((s) => s.id === id);
      if (session && session.status !== "running" && !session.videoError) showTestVideo(session);
      else showLiveStream();
    }

    // Split a step's text into a short white heading and the detailed tail that goes
    // into the collapsible block. Cuts at the earliest of " — ", "; " or " (" (the
    // paren is kept with the tail). No separator → whole text is the heading.
    function splitStep(text) {
      const t = (text || "").trim();
      const dash = t.search(/ — /);
      const semi = t.indexOf("; ");
      const paren = t.search(/ \(/);
      const cands = [];
      if (dash >= 0) cands.push([dash, dash + 3]);
      if (semi >= 0) cands.push([semi, semi + 2]);
      if (paren >= 0) cands.push([paren, paren + 1]);
      if (!cands.length) return { head: t, tail: "" };
      cands.sort((a, b) => a[0] - b[0]);
      const [idx, tailStart] = cands[0];
      const head = t.slice(0, idx).trim();
      return { head: head || t, tail: t.slice(tailStart).trim() };
    }

    function renderTestTimeline() {
      if (activeTab !== "tests") return;
      const session = testsSessions.find((s) => s.id === selectedTestId);
      const prevScroll = captureScroll(testsTimelineEl);
      testsTimelineEl.innerHTML = "";
      if (!session) return;
      const header = document.createElement("div");
      header.className = "tests-timeline-header";
      const headerTitle = document.createElement("span");
      headerTitle.className = "tests-timeline-title";
      headerTitle.textContent = session.title + (session.videoError ? " · video unavailable" : "");
      const headerToggle = document.createElement("span");
      headerToggle.className = "tests-timeline-toggle";
      header.append(headerTitle, headerToggle);
      testsTimelineEl.appendChild(header);

      // Keys of all steps that have a collapsible detail — backs the expand/collapse-all control.
      const detailKeys = [];
      (session.entries || []).forEach((entry, index) => {
        const offset = entryOffsetSeconds(session, entry);
        if (entry.kind === "step") {
          const { head, tail } = splitStep(entry.text);
          const logs = entry.logs || [];
          const hasDetail = !!tail || logs.length > 0;
          const stepKey = selectedTestId + ":" + index;
          const expanded = expandedTestSteps.has(stepKey);
          if (hasDetail) detailKeys.push(stepKey);

          const row = document.createElement("div");
          row.className = "tests-step";
          row.dataset.index = String(index);
          const time = document.createElement("span");
          time.className = "tests-step-t";
          time.textContent = formatOffset(offset);
          const text = document.createElement("span");
          text.className = "tests-step-text";
          text.textContent = head;
          row.append(time, text);
          row.addEventListener("click", () => seekTestVideo(offset));

          let detail;
          if (hasDetail) {
            const toggle = document.createElement("span");
            toggle.className = "tests-step-toggle";
            toggle.textContent = expanded ? "▾" : "▸";
            toggle.title = expanded ? "Свернуть детали" : "Показать детали";
            row.appendChild(toggle);

            detail = document.createElement("div");
            detail.className = "tests-detail";
            detail.hidden = !expanded;
            if (tail) {
              const tailEl = document.createElement("div");
              tailEl.className = "tests-detail-text";
              tailEl.textContent = tail;
              detail.appendChild(tailEl);
            }
            for (const line of logs) {
              const log = document.createElement("div");
              log.className = "tests-logline";
              log.textContent = line;
              detail.appendChild(log);
            }

            toggle.addEventListener("click", (domEvent) => {
              domEvent.stopPropagation();
              const open = expandedTestSteps.has(stepKey);
              if (open) expandedTestSteps.delete(stepKey);
              else expandedTestSteps.add(stepKey);
              detail.hidden = open;
              toggle.textContent = open ? "▸" : "▾";
              toggle.title = open ? "Показать детали" : "Свернуть детали";
            });
          }

          testsTimelineEl.appendChild(row);
          if (detail) testsTimelineEl.appendChild(detail);
        } else {
          const logs = entry.logs || [];
          if (!logs.length) return;
          // A failure log entry carries the error first and a long screen dump
          // after it — keep the first line visible, collapse the rest.
          const collapsible = logs.length > 2;
          const stepKey = selectedTestId + ":" + index;
          const expanded = expandedTestSteps.has(stepKey);
          if (collapsible) detailKeys.push(stepKey);

          const log = document.createElement("div");
          log.className = "tests-log";
          const time = document.createElement("span");
          time.className = "tests-step-t";
          time.textContent = formatOffset(offset);
          const text = document.createElement("span");
          text.textContent = logs[0];
          log.append(time, text);

          if (!collapsible) {
            testsTimelineEl.appendChild(log);
            for (const line of logs.slice(1)) {
              const extra = document.createElement("div");
              extra.className = "tests-log";
              const pad = document.createElement("span");
              pad.className = "tests-step-t";
              const extraText = document.createElement("span");
              extraText.textContent = line;
              extra.append(pad, extraText);
              testsTimelineEl.appendChild(extra);
            }
            return;
          }

          const toggle = document.createElement("span");
          toggle.className = "tests-step-toggle";
          toggle.textContent = (expanded ? "▾" : "▸") + " " + (logs.length - 1);
          toggle.title = expanded ? "Collapse log lines" : "Show " + (logs.length - 1) + " log lines";
          log.appendChild(toggle);

          const detail = document.createElement("div");
          detail.className = "tests-detail";
          detail.hidden = !expanded;
          for (const line of logs.slice(1)) {
            const detailLine = document.createElement("div");
            detailLine.className = "tests-logline";
            detailLine.textContent = line;
            detail.appendChild(detailLine);
          }

          toggle.addEventListener("click", (domEvent) => {
            domEvent.stopPropagation();
            const open = expandedTestSteps.has(stepKey);
            if (open) expandedTestSteps.delete(stepKey);
            else expandedTestSteps.add(stepKey);
            detail.hidden = open;
            toggle.textContent = (open ? "▸" : "▾") + " " + (logs.length - 1);
            toggle.title = open ? "Show " + (logs.length - 1) + " log lines" : "Collapse log lines";
          });

          testsTimelineEl.appendChild(log);
          testsTimelineEl.appendChild(detail);
        }
      });

      // Expand/collapse-all control in the header — collapses all when everything is open,
      // otherwise opens every step that has detail. Hidden when no step has detail.
      if (detailKeys.length) {
        const allOpen = detailKeys.every((k) => expandedTestSteps.has(k));
        headerToggle.textContent = allOpen ? "▾" : "▸";
        headerToggle.title = allOpen ? "Свернуть все шаги" : "Развернуть все шаги";
        headerToggle.addEventListener("click", () => {
          if (detailKeys.every((k) => expandedTestSteps.has(k))) {
            detailKeys.forEach((k) => expandedTestSteps.delete(k));
          } else {
            detailKeys.forEach((k) => expandedTestSteps.add(k));
          }
          renderTestTimeline();
        });
      } else {
        headerToggle.hidden = true;
      }

      restoreScroll(testsTimelineEl, "bottom", prevScroll);
    }

    function seekTestVideo(offsetSeconds) {
      const session = testsSessions.find((s) => s.id === selectedTestId);
      if (!session || session.status === "running") return;
      if (playbackTestId !== session.id) showTestVideo(session);
      testVideo.currentTime = offsetSeconds;
      testVideo.play().catch(() => {});
    }

    // ---- Inspector shell: Inspect toggle, tabs, drill-down, resizable drawer ----

    let inspectorOpen = false;
    let activeTab = "network";
    let inspectorView = "list";
    // Empty until /config reports a logApp; the notice stays visible on app-scoped tabs so the
    // user learns why they are empty instead of watching blank panes. Gated on the config fetch
    // so it cannot flash before the attached app is known.
    let attachedApp = "";
    let attachedAppKnown = false;
    const APP_SCOPED_TABS = ["network", "logs", "state"];

    function updateInspectorNotice() {
      inspectorNotice.hidden = !attachedAppKnown || !!attachedApp || !APP_SCOPED_TABS.includes(activeTab);
    }

    for (const codeEl of [inspectorNoticeCmd, inspectorNoticeRunCmd]) {
      codeEl.addEventListener("click", () => {
        if (navigator.clipboard) navigator.clipboard.writeText(codeEl.textContent).catch(() => {});
      });
    }
    const filterByTab = { network: "", logs: "", state: "", ax: "", tests: "" };

    const FILTER_PLACEHOLDER = {
      network: "filter service / status / host",
      logs: "filter message / subsystem",
      state: "filter model id",
      ax: "filter id / label / role",
      tests: "filter title / status"
    };

    function showDetailView(label) {
      inspectorView = "detail";
      detailBackLabel.textContent = label;
      inspectorListView.hidden = true;
      inspectorDetailView.hidden = false;
    }

    function showListView() {
      inspectorView = "list";
      inspectorDetailView.hidden = true;
      inspectorListView.hidden = false;
    }

    function setActiveTab(tab) {
      activeTab = tab;
      for (const key in tabButtons) tabButtons[key].classList.toggle("active", key === tab);
      networkList.hidden = tab !== "network";
      logsControls.hidden = tab !== "logs";
      logsList.hidden = tab !== "logs";
      statePane.hidden = tab !== "state";
      axPane.hidden = tab !== "ax";
      testsPane.hidden = tab !== "tests";
      inspectorFilter.value = filterByTab[tab] || "";
      inspectorFilter.placeholder = FILTER_PLACEHOLDER[tab] || "";
      inspectorFilter.disabled = false;
      renderFilterChips();
      updateInspectorNotice();
      if (tab !== "network") { hideNetworkMenu(); hideNetworkLaunchMenu(); }
      if (tab !== "logs") { hideLogsMenu(); hideLogsLaunchMenu(); }
      if (tab !== "tests") hideTestsMenu();
      hideFilterHelp();
      showListView();
      if (tab === "network") renderNetworkList();
      else if (tab === "logs") { renderLogsList(); ensureLogs(); }
      else if (tab === "state") renderState();
      else if (tab === "ax") { renderAxTree(); renderAxSelected(); }
      else if (tab === "tests") { renderFlowsList(); renderTestsList(); renderTestTimeline(); }
      if (tab === "state") startStatePolling(); else stopStatePolling();
      if (tab === "ax") startAxPolling(); else stopAxPolling();
      if (tab === "tests") startTestsPolling(); else { stopTestsPolling(); showLiveStream(); }
      axUpdateCanvasMode();
      renderAxOverlay();
    }

    function setInspectorOpen(open) {
      inspectorOpen = open;
      inspector.hidden = !open;
      stage.classList.toggle("inspector-open", open);
      inspectToggle.classList.toggle("on", open);
      inspectToggle.setAttribute("aria-pressed", String(open));
      if (open) {
        updateInspectorLayout();
        startNetworkPolling();
        if (logsCaptureStarted) startLogsPolling();
        setActiveTab(activeTab);
      } else {
        stopNetworkPolling();
        stopLogsPolling();
        stopStatePolling();
        stopAxPolling();
        stopTestsPolling();
        showLiveStream();
        axUpdateCanvasMode();
        renderAxOverlay();
        hideAxMenu();
        hideNetworkMenu();
        hideLogsMenu();
        hideTestsMenu();
        hideFilterHelp();
      }
    }

    inspectToggle.addEventListener("click", () => setInspectorOpen(!inspectorOpen));
    detailBack.addEventListener("click", showListView);
    for (const key in tabButtons) {
      tabButtons[key].addEventListener("click", () => setActiveTab(key));
    }
    inspectorFilter.addEventListener("input", () => {
      filterByTab[activeTab] = inspectorFilter.value;
      if (activeTab === "network") renderNetworkList();
      else if (activeTab === "logs") renderLogsList();
      else if (activeTab === "state") renderState();
      else if (activeTab === "ax") { axFilter = inspectorFilter.value; renderAxTree(); }
      else if (activeTab === "tests") renderTestsList();
    });
    inspectorFilter.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        const text = inspectorFilter.value.trim();
        if (!text) return;
        event.preventDefault();
        inspectorFilter.value = "";
        filterByTab[activeTab] = "";
        if (activeTab === "ax") axFilter = "";
        const allowedFields = activeTab === "logs" ? LOGS_FILTER_FIELDS : null;
        const kind = text.startsWith("-") ? "exclude" : "include";
        const parsed = parseFieldTerm(kind === "exclude" ? text.slice(1) : text, allowedFields);
        addFilterChip(kind, parsed.term, parsed.field);
        rerenderActiveTab();
      } else if (event.key === "Backspace" && !inspectorFilter.value && filterChipsByTab[activeTab].length) {
        removeFilterChip(filterChipsByTab[activeTab].length - 1);
      }
    });

    // ---- Resizable drawer ----

    const DRAWER_MIN = 120;
    let savedDrawerHeight = null;
    try { savedDrawerHeight = parseInt(localStorage.getItem("simtool.drawerHeight") || "", 10) || null; } catch (_) {}

    function clampDrawerHeight(h) {
      const max = Math.max(DRAWER_MIN, stage.clientHeight - 60);
      return Math.max(DRAWER_MIN, Math.min(max, h));
    }

    function applyDrawerHeight(h) {
      inspector.style.height = clampDrawerHeight(h) + "px";
    }

    // Wide stage → inspector docks as a right column beside the device; narrow → bottom drawer.
    const SIDE_MIN_WIDTH = 680;
    function updateInspectorLayout() {
      const side = stage.clientWidth >= SIDE_MIN_WIDTH;
      stage.classList.toggle("layout-side", side);
      if (side) {
        inspector.style.height = "";
      } else {
        inspector.style.height = savedDrawerHeight ? clampDrawerHeight(savedDrawerHeight) + "px" : "";
      }
    }

    let dragging = false;
    let dragStartY = 0;
    let dragStartHeight = 0;
    drawerHandle.addEventListener("pointerdown", (event) => {
      if (stage.classList.contains("layout-side")) return;
      dragging = true;
      dragStartY = event.clientY;
      dragStartHeight = inspector.getBoundingClientRect().height;
      try { drawerHandle.setPointerCapture(event.pointerId); } catch (_) {}
      event.preventDefault();
    });
    drawerHandle.addEventListener("pointermove", (event) => {
      if (!dragging) return;
      applyDrawerHeight(dragStartHeight - (event.clientY - dragStartY));
    });
    function endDrag(event) {
      if (!dragging) return;
      dragging = false;
      try { drawerHandle.releasePointerCapture(event.pointerId); } catch (_) {}
      const height = Math.round(inspector.getBoundingClientRect().height);
      savedDrawerHeight = height;
      try { localStorage.setItem("simtool.drawerHeight", String(height)); } catch (_) {}
    }
    drawerHandle.addEventListener("pointerup", endDrag);
    drawerHandle.addEventListener("pointercancel", endDrag);

    // ---- Resizable card width ----

    const viewerCard = $("viewerCard");
    const CARD_MIN_WIDTH = 480;

    function applyCardWidth(w) {
      // The CSS min() against the viewport keeps the card on screen; only the
      // floor needs enforcing here.
      viewerCard.style.setProperty("--card-w", Math.max(CARD_MIN_WIDTH, w) + "px");
      updateInspectorLayout();
      updateSurfaceSize();
    }

    try {
      const saved = parseInt(localStorage.getItem("simtool.cardWidth") || "", 10);
      if (saved) applyCardWidth(saved);
    } catch (_) {}

    function wireCardResize(handle, direction) {
      let drag = null;
      handle.addEventListener("pointerdown", (event) => {
        drag = { startX: event.clientX, startWidth: viewerCard.getBoundingClientRect().width };
        handle.classList.add("active");
        try { handle.setPointerCapture(event.pointerId); } catch (_) {}
        event.preventDefault();
      });
      handle.addEventListener("pointermove", (event) => {
        if (!drag) return;
        // The card stays centered, so the dragged edge tracks the pointer at 2x.
        applyCardWidth(drag.startWidth + direction * (event.clientX - drag.startX) * 2);
      });
      function endCardDrag(event) {
        if (!drag) return;
        drag = null;
        handle.classList.remove("active");
        try { handle.releasePointerCapture(event.pointerId); } catch (_) {}
        const width = Math.round(viewerCard.getBoundingClientRect().width);
        try { localStorage.setItem("simtool.cardWidth", String(width)); } catch (_) {}
      }
      handle.addEventListener("pointerup", endCardDrag);
      handle.addEventListener("pointercancel", endCardDrag);
    }
    wireCardResize($("cardResizeLeft"), -1);
    wireCardResize($("cardResizeRight"), 1);

    // ---- Wiring ----

    homeButton.addEventListener("click", pressHome);
    shotButton.addEventListener("click", downloadScreenshot);
    shakeButton.addEventListener("click", pressShake);
    terminateButton.addEventListener("click", pressTerminate);
    relaunchButton.addEventListener("click", pressRelaunch);
    axRefreshButton.addEventListener("click", loadAxTree);
    axCopyButton.addEventListener("click", copyAxSelected);
    axMenuCopy.addEventListener("click", () => { copyAxNode(axMenuNode); hideAxMenu(); });
    networkMenuExclude.addEventListener("click", () => { addFilterChip("exclude", networkMenuPath); hideNetworkMenu(); });
    networkMenuInclude.addEventListener("click", () => { addFilterChip("include", networkMenuPath); hideNetworkMenu(); });
    networkLaunchMenuDelete.addEventListener("click", async () => {
      const launchId = networkLaunchMenuId;
      hideNetworkLaunchMenu();
      if (launchId == null) return;
      try {
        const response = await fetch("/api/v1/network/launches/" + encodeURIComponent(launchId), { method: "DELETE" });
        if (!response.ok) return;
      } catch (_) { return; }
      collapsedNetworkLaunches.delete(String(launchId));
      const selected = networkEvents.find((event) => event.id === networkSelectedId);
      if (selected && selected.launchId === launchId) {
        networkSelectedId = null;
        showListView();
      }
      loadNetwork();
    });
    logsLaunchMenuDelete.addEventListener("click", async () => {
      const launchId = logsLaunchMenuId;
      hideLogsLaunchMenu();
      if (launchId == null) return;
      try {
        const response = await fetch("/api/v1/logs/launches/" + encodeURIComponent(launchId), { method: "DELETE" });
        if (!response.ok) return;
      } catch (_) { return; }
      collapsedLogLaunches.delete(String(launchId));
      // Logs accumulate client-side across cursor polls, so drop the launch's entries locally too.
      logsEntries = logsEntries.filter((entry) => entry.launchId !== launchId);
      renderLogsList();
    });
    logsMenuCopy.addEventListener("click", () => {
      if (logsMenuEntry) axWriteClipboard(logEntryText(logsMenuEntry));
      hideLogsMenu();
    });
    logsMenuCopySel.addEventListener("click", () => {
      if (logsMenuSelection) axWriteClipboard(logsMenuSelection);
      hideLogsMenu();
    });
    // Chips are matched against a single-line haystack, so a multi-line
    // selection is collapsed to one line before it becomes a filter term.
    function logsSelectionChipTerm() {
      return logsMenuSelection.replace(/\s+/g, " ").trim();
    }
    logsMenuIncludeSel.addEventListener("click", () => {
      const term = logsSelectionChipTerm();
      hideLogsMenu();
      if (term) addFilterChip("include", term);
    });
    logsMenuExcludeSel.addEventListener("click", () => {
      const term = logsSelectionChipTerm();
      hideLogsMenu();
      if (term) addFilterChip("exclude", term);
    });
    testsMenuDelete.addEventListener("click", async () => {
      const id = testsMenuSessionId;
      hideTestsMenu();
      if (!id) return;
      try {
        const response = await fetch("/api/v1/tests/" + encodeURIComponent(id), { method: "DELETE" });
        if (!response.ok) return;
      } catch (_) { return; }
      if (playbackTestId === id) showLiveStream();
      if (selectedTestId === id) selectedTestId = null;
      testsLastPayload = "";
      loadTests();
    });
    filterHelp.addEventListener("click", (event) => {
      event.stopPropagation();
      if (filterHelpPop.hidden) showFilterHelp(); else hideFilterHelp();
    });
    function hidePopups() { hideAxMenu(); hideNetworkMenu(); hideNetworkLaunchMenu(); hideLogsMenu(); hideLogsLaunchMenu(); hideTestsMenu(); hideFilterHelp(); }
    document.addEventListener("click", (event) => {
      if (!axMenu.hidden && !axMenu.contains(event.target)) hideAxMenu();
      if (!networkMenu.hidden && !networkMenu.contains(event.target)) hideNetworkMenu();
      if (!networkLaunchMenu.hidden && !networkLaunchMenu.contains(event.target)) hideNetworkLaunchMenu();
      if (!logsMenu.hidden && !logsMenu.contains(event.target)) hideLogsMenu();
      if (!logsLaunchMenu.hidden && !logsLaunchMenu.contains(event.target)) hideLogsLaunchMenu();
      if (!testsMenu.hidden && !testsMenu.contains(event.target)) hideTestsMenu();
      if (!filterHelpPop.hidden && !filterHelpPop.contains(event.target)) hideFilterHelp();
    });
    document.addEventListener("keydown", (event) => { if (event.key === "Escape") hidePopups(); });
    window.addEventListener("scroll", () => hidePopups(), true);

    // Canvas pointer gestures: a near-stationary press is a tap, a drag is a swipe.
    const TAP_MOVE_THRESHOLD = 8;     // CSS px of movement below which a gesture is a tap
    const SWIPE_MIN_DURATION = 0.05;  // seconds — keeps a fast flick usable
    const SWIPE_MAX_DURATION = 2.0;   // seconds — caps an absurdly slow drag
    let gesture = null;

    canvas.addEventListener("pointerdown", (event) => {
      if (!streamWidth || !streamHeight) return;
      if (event.button !== 0) return; // primary button / touch only
      gesture = {
        pointerId: event.pointerId,
        startClientX: event.clientX,
        startClientY: event.clientY,
        startPoint: eventToSimulatorPoint(event, canvas),
        startTime: performance.now()
      };
      try { canvas.setPointerCapture(event.pointerId); } catch (_) {}
      event.preventDefault();
    });

    canvas.addEventListener("pointerup", (event) => {
      if (!gesture || event.pointerId !== gesture.pointerId) return;
      const start = gesture;
      gesture = null;
      try { canvas.releasePointerCapture(event.pointerId); } catch (_) {}
      if (axSelectMode()) {
        const node = axHitTest(event.clientX, event.clientY);
        if (node) selectAxNode(node._key, true);
        return;
      }
      const moved = Math.hypot(event.clientX - start.startClientX, event.clientY - start.startClientY);
      if (moved < TAP_MOVE_THRESHOLD) {
        sendTap(start.startPoint);
        return;
      }
      const endPoint = eventToSimulatorPoint(event, canvas);
      const elapsedSeconds = (performance.now() - start.startTime) / 1000;
      const duration = Math.min(SWIPE_MAX_DURATION, Math.max(SWIPE_MIN_DURATION, elapsedSeconds));
      sendSwipe(start.startPoint, endPoint, duration);
    });

    canvas.addEventListener("pointercancel", (event) => {
      if (!gesture || event.pointerId !== gesture.pointerId) return;
      try { canvas.releasePointerCapture(gesture.pointerId); } catch (_) {}
      gesture = null;
    });

    // Right-click on the device screen (AX mode only): select the element under the
    // cursor and open the Copy menu for it.
    canvas.addEventListener("contextmenu", (event) => {
      if (!axSelectMode()) return;
      event.preventDefault();
      const node = axHitTest(event.clientX, event.clientY);
      if (!node) return;
      selectAxNode(node._key, true);
      showAxMenu(event.clientX, event.clientY, node);
    });
    function onResize() { updateInspectorLayout(); updateSurfaceSize(); }
    window.addEventListener("resize", onResize);
    updateInspectorLayout();

    // The viewer streams H.264/AVCC over WebCodecs exclusively. There is no JPEG/MJPEG fallback,
    // so a browser without WebCodecs VideoDecoder surfaces a clear error instead of degrading.
    startAvcc().catch((error) => {
      placeholder.textContent = `stream unavailable: ${error.message}`;
      placeholder.style.display = "grid";
      setStatus(`stream failed: ${error.message}`, "err");
    });

    async function bootstrap() {
      try {
        const response = await api("/config");
        const config = await response.json();
        if (config.device) deviceName.textContent = config.device;
        attachedApp = config.logApp || "";
        attachedAppKnown = true;
        if (attachedApp) {
          // Pre-scope log capture to the server's default app so logs are already buffering when
          // the inspector is opened. Polling only starts once the inspector is shown.
          logsTargetApp = attachedApp;
          await startLogsCapture();
          if (inspectorOpen) startLogsPolling();
        } else {
          const port = location.port ? ` --port ${location.port}` : "";
          const device = config.udid ? ` --device ${config.udid}` : "";
          inspectorNoticeCmd.textContent = `simtool serve --app <bundle-id>${device}${port} --web`;
        }
        updateInspectorNotice();
      } catch (_) {}
    }
    bootstrap();
    """#
}
