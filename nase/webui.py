from __future__ import annotations

import argparse
import json
import traceback
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from . import DEFAULT_BOTTLE_NAME
from .bottle import bottle_paths, ensure_bottle_dirs, external_prefix_paths
from .doctor import apply_doctor_fixes, run_doctor
from .dxmt import install_dxmt
from .runtime import detect_wine_runtime, resolve_with_fallback, run_logged
from .steam import launch_app, list_installed_apps, run_steam
from .winetricks import run_winetricks


def _json_response(handler: BaseHTTPRequestHandler, payload: dict[str, Any], status: int = HTTPStatus.OK) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _html_response(handler: BaseHTTPRequestHandler, html: str) -> None:
    body = html.encode("utf-8")
    handler.send_response(HTTPStatus.OK)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _current_bottle(config: dict[str, Any]):
    if config.get("mode") == "external" and config.get("prefix"):
        return external_prefix_paths(Path(str(config["prefix"])))
    name = str(config.get("bottle") or DEFAULT_BOTTLE_NAME).strip() or DEFAULT_BOTTLE_NAME
    return bottle_paths(name)


def _resolve_wine(config: dict[str, Any]) -> Path:
    value = str(config.get("wine") or "").strip()
    if not value:
        raise FileNotFoundError("Wine path is required")
    return resolve_with_fallback(value, "wine", ("wine",))


def _backend_setup_metal(config: dict[str, Any]) -> dict[str, Any]:
    bottle = _current_bottle(config)
    wine = _resolve_wine(config)
    dxmt_source = Path(str(config.get("dxmt_source") or "")).expanduser()
    if not dxmt_source.exists():
        raise FileNotFoundError(f"DXMT source not found: {dxmt_source}")

    ensure_bottle_dirs(bottle)
    runtime = detect_wine_runtime(wine)
    lines = [f"Target prefix: {bottle.prefix}", f"Wine runtime: {runtime.get('version_output') or wine}"]
    if not runtime.get("is_stable_11"):
        lines.append("Warning: this flow is tuned for Wine Stable 11.0.")

    code, tail = run_logged(
        cmd=[str(wine), "wineboot", "-u"],
        env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
        log_file=bottle.logs / "01_wineboot.log",
    )
    if code != 0:
        raise RuntimeError(f"wineboot failed:\n{tail}")
    lines.append("wineboot completed.")

    code, tail = run_winetricks(
        bottle=bottle,
        winetricks_path=resolve_with_fallback("winetricks", "winetricks", ("winetricks",)),
        verbs=["steam"],
        log_name="02_winetricks_steam.log",
        unattended=True,
    )
    if code != 0:
        raise RuntimeError(f"winetricks steam failed:\n{tail}")
    lines.append("winetricks steam completed.")

    code, tail = install_dxmt(bottle=bottle, dxmt_source=dxmt_source, wine64_path=wine)
    if code != 0:
        raise RuntimeError(f"install-dxmt failed:\n{tail}")
    lines.append("DXMT installed.")

    code, tail = run_steam(bottle=bottle, wine64_path=wine, wait=False, graphics_backend="none")
    if code != 0:
        raise RuntimeError(f"Steam launch failed:\n{tail}")
    lines.append("Steam launched.")
    return {"log": "\n".join(lines)}


def _backend_doctor(config: dict[str, Any], *, fix: bool) -> dict[str, Any]:
    bottle = _current_bottle(config)
    wine_value = str(config.get("wine") or "").strip() or None
    lines: list[str] = []

    if fix:
        actions = apply_doctor_fixes(
            bottle=bottle,
            wine_value=wine_value,
            dxmt_source=str(config.get("dxmt_source") or "").strip() or None,
        )
        lines.extend(f"[FIX ] {action}" for action in actions)

    results = run_doctor(bottle=bottle, wine_value=wine_value, winetricks_value="winetricks")
    lines.extend(f"[{result.status.upper():4}] {result.name}: {result.detail}" for result in results)
    return {"log": "\n".join(lines)}


def _backend_open_steam(config: dict[str, Any]) -> dict[str, Any]:
    bottle = _current_bottle(config)
    wine = _resolve_wine(config)
    code, tail = run_steam(bottle=bottle, wine64_path=wine, wait=False, graphics_backend="none")
    if code != 0:
        raise RuntimeError(f"Steam launch failed:\n{tail}")
    return {"log": f"Launched Steam for {bottle.prefix}"}


def _backend_list_games(config: dict[str, Any]) -> dict[str, Any]:
    apps = list_installed_apps(_current_bottle(config))
    return {
        "games": [{"appid": app.appid, "name": app.name} for app in apps],
        "log": f"Found {len(apps)} game(s).",
    }


def _backend_launch_game(config: dict[str, Any]) -> dict[str, Any]:
    appid = str(config.get("appid") or "").strip()
    if not appid:
        raise ValueError("AppID is required")
    bottle = _current_bottle(config)
    wine = _resolve_wine(config)
    code, tail = launch_app(bottle=bottle, wine64_path=wine, appid=appid, graphics_backend="dxmt")
    if code != 0:
        raise RuntimeError(f"Game launch failed:\n{tail}")
    return {"log": f"Launched game {appid}."}


def _defaults(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "mode": "external" if getattr(args, "prefix", None) else "managed",
        "bottle": getattr(args, "bottle", DEFAULT_BOTTLE_NAME) or DEFAULT_BOTTLE_NAME,
        "prefix": getattr(args, "prefix", "") or "",
        "wine": getattr(args, "wine64", None) or getattr(args, "wine", None) or "/opt/homebrew/bin/wine",
        "dxmt_source": str((Path.home() / "Downloads" / "dxmt").expanduser()),
    }


def _page(defaults: dict[str, Any]) -> str:
    defaults_json = json.dumps(defaults)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SteamWineWrapper</title>
  <style>
    :root {{
      --paper: #f3ead9;
      --card: #fbf5e9;
      --ink: #2f2018;
      --muted: #725c4b;
      --accent: #a44d2f;
      --accent-2: #d88d58;
      --line: #ddcfb8;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font-family: "Avenir Next", "Helvetica Neue", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, #fff5df 0, transparent 30%),
        linear-gradient(135deg, #f1e5cf 0%, var(--paper) 42%, #efe1ca 100%);
    }}
    .shell {{
      max-width: 1320px;
      margin: 0 auto;
      padding: 24px;
    }}
    .hero {{
      padding: 24px 28px;
      border: 1px solid var(--line);
      background: linear-gradient(145deg, rgba(255,250,240,.92), rgba(245,234,213,.96));
      border-radius: 24px;
      box-shadow: 0 24px 60px rgba(83, 49, 28, .10);
    }}
    .hero h1 {{
      margin: 0;
      font-size: 40px;
      line-height: 1;
      letter-spacing: -.04em;
    }}
    .hero p {{
      margin: 10px 0 0;
      color: var(--muted);
      max-width: 760px;
      font-size: 16px;
    }}
    .grid {{
      display: grid;
      grid-template-columns: 1.2fr .8fr;
      gap: 18px;
      margin-top: 18px;
    }}
    .card {{
      background: rgba(251, 245, 233, .92);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 18px;
      box-shadow: 0 18px 40px rgba(92, 56, 31, .06);
    }}
    .card h2 {{
      margin: 0 0 14px;
      font-size: 18px;
      letter-spacing: -.02em;
    }}
    .row {{
      display: grid;
      grid-template-columns: 128px 1fr auto;
      gap: 10px;
      align-items: center;
      margin-bottom: 12px;
    }}
    .row label {{ color: var(--muted); font-size: 14px; }}
    input[type=text] {{
      width: 100%;
      padding: 12px 14px;
      border-radius: 14px;
      border: 1px solid #d7c6ad;
      background: #fffaf3;
      color: var(--ink);
      font-size: 14px;
    }}
    .segmented {{
      display: flex;
      gap: 8px;
      margin-bottom: 14px;
    }}
    .segmented button {{
      flex: 1;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: #fff9ef;
      color: var(--muted);
      padding: 10px 14px;
      cursor: pointer;
      font-weight: 600;
    }}
    .segmented button.active {{
      background: linear-gradient(135deg, var(--accent), var(--accent-2));
      color: white;
      border-color: transparent;
    }}
    .actions {{
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
    }}
    .actions button {{
      border: 0;
      border-radius: 14px;
      padding: 12px 14px;
      cursor: pointer;
      font-weight: 700;
      letter-spacing: .01em;
      color: white;
      background: linear-gradient(135deg, var(--accent), var(--accent-2));
      box-shadow: 0 10px 24px rgba(164, 77, 47, .22);
    }}
    .muted-btn {{
      background: linear-gradient(135deg, #7f634d, #a68368) !important;
    }}
    .status {{
      margin-top: 14px;
      color: var(--muted);
      font-size: 14px;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      margin-top: 10px;
    }}
    th, td {{
      text-align: left;
      padding: 10px 8px;
      border-bottom: 1px solid #eadfcd;
      font-size: 14px;
    }}
    tr:hover td {{
      background: rgba(255, 250, 243, .75);
    }}
    tr.selected td {{
      background: rgba(216, 141, 88, .18);
    }}
    pre {{
      margin: 0;
      height: 420px;
      overflow: auto;
      border-radius: 16px;
      padding: 14px;
      background: #fffaf3;
      border: 1px solid #e7d9c3;
      color: #3b2a1e;
      font: 13px/1.45 "SF Mono", ui-monospace, monospace;
      white-space: pre-wrap;
    }}
    @media (max-width: 980px) {{
      .grid {{ grid-template-columns: 1fr; }}
      .row {{ grid-template-columns: 1fr; }}
      .actions {{ grid-template-columns: 1fr; }}
    }}
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <h1>SteamWineWrapper</h1>
      <p>Metal-first Steam setup for macOS. Managed bottles are the default path, but we can still point at an external Wine prefix when we need to import an existing setup.</p>
    </section>

    <div class="grid">
      <section class="card">
        <h2>Configuration</h2>
        <div class="segmented">
          <button id="mode-managed" onclick="setMode('managed')">Managed Bottle</button>
          <button id="mode-external" onclick="setMode('external')">External Prefix</button>
        </div>

        <div class="row">
          <label for="bottle">Bottle</label>
          <input id="bottle" type="text">
          <div></div>
        </div>
        <div class="row">
          <label for="prefix">Prefix</label>
          <input id="prefix" type="text">
          <div class="status">Paste full path</div>
        </div>
        <div class="row">
          <label for="wine">Wine</label>
          <input id="wine" type="text">
          <div class="status">Paste full path</div>
        </div>
        <div class="row">
          <label for="dxmt-source">DXMT Source</label>
          <input id="dxmt-source" type="text">
          <div class="status">Paste full path</div>
        </div>

        <div class="actions">
          <button onclick="runAction('setup-metal')">Setup Metal</button>
          <button onclick="runAction('doctor')">Doctor</button>
          <button onclick="runAction('doctor-fix')">Doctor + Fix</button>
          <button class="muted-btn" onclick="runAction('open-steam')">Open Steam</button>
          <button class="muted-btn" onclick="runAction('list-games')">Refresh Games</button>
          <button onclick="launchSelected()">Launch Selected</button>
        </div>
        <div class="status" id="status">Ready</div>
      </section>

      <section class="card">
        <h2>Steam Games</h2>
        <table>
          <thead><tr><th>AppID</th><th>Game</th></tr></thead>
          <tbody id="games"></tbody>
        </table>
      </section>
    </div>

    <section class="card" style="margin-top: 18px;">
      <h2>Activity</h2>
      <pre id="log">Frontend ready.</pre>
    </section>
  </div>

  <script>
    const defaults = {defaults_json};
    let selectedAppId = null;

    function byId(id) {{
      return document.getElementById(id);
    }}

    function applyDefaults() {{
      byId('bottle').value = defaults.bottle || 'Default';
      byId('prefix').value = defaults.prefix || '';
      byId('wine').value = defaults.wine || '/opt/homebrew/bin/wine';
      byId('dxmt-source').value = defaults.dxmt_source || '';
      setMode(defaults.mode || 'managed');
    }}

    function setMode(mode) {{
      defaults.mode = mode;
      byId('mode-managed').classList.toggle('active', mode === 'managed');
      byId('mode-external').classList.toggle('active', mode === 'external');
      byId('bottle').disabled = mode !== 'managed';
      byId('prefix').disabled = mode !== 'external';
    }}

    function config() {{
      return {{
        mode: defaults.mode,
        bottle: byId('bottle').value.trim(),
        prefix: byId('prefix').value.trim(),
        wine: byId('wine').value.trim(),
        dxmt_source: byId('dxmt-source').value.trim(),
      }};
    }}

    function setStatus(text) {{
      byId('status').textContent = text;
    }}

    function appendLog(text) {{
      const log = byId('log');
      log.textContent += "\\n\\n" + text;
      log.scrollTop = log.scrollHeight;
    }}

    function renderGames(games) {{
      const tbody = byId('games');
      tbody.innerHTML = '';
      selectedAppId = null;
      for (const game of games || []) {{
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${{game.appid}}</td><td>${{game.name}}</td>`;
        tr.onclick = () => {{
          selectedAppId = game.appid;
          document.querySelectorAll('#games tr').forEach(row => row.classList.remove('selected'));
          tr.classList.add('selected');
        }};
        tbody.appendChild(tr);
      }}
    }}

    async function api(path, payload) {{
      const response = await fetch(path, {{
        method: 'POST',
        headers: {{ 'Content-Type': 'application/json' }},
        body: JSON.stringify(payload),
      }});
      const data = await response.json();
      if (!response.ok || data.ok === false) {{
        throw new Error(data.error || 'Request failed');
      }}
      return data;
    }}

    async function runAction(action) {{
      setStatus(`Running ${{action}}...`);
      try {{
        const data = await api(`/api/${{action}}`, config());
        if (data.log) appendLog(data.log);
        if (data.games) renderGames(data.games);
        setStatus(`${{action}} finished`);
      }} catch (error) {{
        appendLog(`${{action}} failed: ${{error.message}}`);
        setStatus(`${{action}} failed`);
      }}
    }}

    async function launchSelected() {{
      if (!selectedAppId) {{
        appendLog('Select a game first.');
        return;
      }}
      await runActionWithPayload('launch-game', {{ ...config(), appid: selectedAppId }});
    }}

    async function runActionWithPayload(action, payload) {{
      setStatus(`Running ${{action}}...`);
      try {{
        const data = await api(`/api/${{action}}`, payload);
        if (data.log) appendLog(data.log);
        if (data.games) renderGames(data.games);
        setStatus(`${{action}} finished`);
      }} catch (error) {{
        appendLog(`${{action}} failed: ${{error.message}}`);
        setStatus(`${{action}} failed`);
      }}
    }}

    applyDefaults();
  </script>
</body>
</html>
"""


class _Handler(BaseHTTPRequestHandler):
    server: "_AppServer"

    def do_GET(self) -> None:
        if self.path == "/":
            _html_response(self, _page(self.server.defaults))
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        try:
            if self.path == "/api/setup-metal":
                response = _backend_setup_metal(payload)
            elif self.path == "/api/doctor":
                response = _backend_doctor(payload, fix=False)
            elif self.path == "/api/doctor-fix":
                response = _backend_doctor(payload, fix=True)
            elif self.path == "/api/open-steam":
                response = _backend_open_steam(payload)
            elif self.path == "/api/list-games":
                response = _backend_list_games(payload)
            elif self.path == "/api/launch-game":
                response = _backend_launch_game(payload)
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
        except Exception as exc:
            _json_response(
                self,
                {"ok": False, "error": str(exc), "traceback": traceback.format_exc()},
                status=HTTPStatus.BAD_REQUEST,
            )
            return

        _json_response(self, {"ok": True, **response})

    def log_message(self, format: str, *args) -> None:
        return


class _AppServer(ThreadingHTTPServer):
    def __init__(self, address, handler, defaults):
        super().__init__(address, handler)
        self.daemon_threads = True
        self.defaults = defaults


def launch_gui(args: argparse.Namespace) -> None:
    defaults = _defaults(args)
    server = _AppServer(("127.0.0.1", 0), _Handler, defaults)
    host, port = server.server_address
    url = f"http://{host}:{port}/"

    print(f"SteamWineWrapper web UI listening at {url}")
    if not getattr(args, "no_browser", False):
        try:
            webbrowser.open(url)
        except Exception:
            pass

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down SteamWineWrapper web UI...")
    finally:
        server.server_close()
