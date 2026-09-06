#!/usr/bin/env python3
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tomllib
from pathlib import Path

NEUTRAL_ACTION = "spawn:true"
BUILTIN_CHORDS = {
    "Mod+Escape", "Mod+Q", "Mod+F1",
    "Mod+Left", "Mod+H", "Mod+Right", "Mod+L", "Mod+Up", "Mod+K", "Mod+Down", "Mod+J",
    "Mod+Shift+Left", "Mod+Shift+H", "Mod+Shift+Right", "Mod+Shift+L",
    "Mod+Shift+Up", "Mod+Shift+K", "Mod+Shift+Down", "Mod+Shift+J",
    "Mod+Comma", "Mod+Period", "Mod+R", "Mod+Shift+R", "Mod+F", "Mod+Ctrl+F",
    "Mod+M", "Mod+T", "Mod+P", "Mod+O", "Mod+WheelUp", "Mod+WheelDown",
}
BUILTIN_CHORDS.update({f"Mod+{n}" for n in range(1, 10)})
BUILTIN_CHORDS.update({f"Mod+Shift+{n}" for n in range(1, 10)})
BUILTIN_CHORDS.update({f"Mod+KP_{n}" for n in range(1, 10)})
BUILTIN_CHORDS.update({f"Mod+Shift+KP_{n}" for n in range(1, 10)})

DESCRIPTIONS = {
    "overview-toggle": "Umbriel Overview",
    "session-quit": "Quit Umbriel",
    "dpms-off": "Power off monitors",
    "window-toggle-maximize": "Maximize column",
    "window-toggle-maximize-to-edges": "Maximize to edges",
    "window-toggle-fullscreen": "Fullscreen",
    "window-toggle-floating": "Toggle floating",
    "window-focus-switch-floating": "Switch float/tile focus",
    "window-cycle-width": "Cycle column width",
    "column-center": "Center column",
    "window-consume-or-expel-left": "Consume/expel left",
    "window-consume-or-expel-right": "Consume/expel right",
    "window-focus-left": "Focus left",
    "window-focus-right": "Focus right",
    "window-focus-up": "Focus up",
    "window-focus-down": "Focus down",
    "column-focus-first": "Focus first column",
    "column-focus-last": "Focus last column",
    "column-move-left": "Move left",
    "column-move-right": "Move right",
    "window-move-up": "Move up",
    "window-move-down": "Move down",
    "column-move-to-first": "Move to first",
    "column-move-to-last": "Move to last",
    "workspace-next": "Next workspace",
    "workspace-previous": "Previous workspace",
    "column-move-to-workspace-next": "Move to next workspace",
    "column-move-to-workspace-previous": "Move to previous workspace",
    "window-focus-next": "Next window",
    "window-focus-previous": "Previous window",
}
IPC_DESCRIPTIONS = {
    ("overlay", "toggle"): "iNiR Overlay",
    ("overview", "toggle"): "iNiR Overview",
    ("clipboard", "toggle"): "Clipboard",
    ("lock", "activate"): "Lock screen",
    ("lock", "focus"): "Refocus lock screen",
    ("region", "menu"): "Screenshot menu",
    ("region", "ocr"): "OCR region",
    ("region", "search"): "Reverse image search",
    ("region", "recordWithSound"): "Record region with audio",
    ("wallpaperSelector", "toggle"): "Wallpaper selector",
    ("settings", "open"): "Settings",
    ("cheatsheet", "toggle"): "Cheatsheet",
    ("panelFamily", "cycle"): "Cycle panel style",
    ("session", "toggle"): "Session dialog",
    ("equalizer", "toggle"): "Equalizer",
    ("audio", "volumeUp"): "Volume up",
    ("audio", "volumeDown"): "Volume down",
    ("audio", "mute"): "Mute audio",
    ("audio", "micMute"): "Mute microphone",
    ("brightness", "increment"): "Brightness up",
    ("brightness", "decrement"): "Brightness down",
    ("mpris", "playPause"): "Play/Pause",
    ("mpris", "next"): "Next track",
    ("mpris", "previous"): "Previous track",
    ("umbriel-screenshot", "screen"): "Screenshot screen",
    ("umbriel-screenshot", "window"): "Screenshot window",
}


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))


def root_config(path: str | None = None) -> Path:
    return Path(path).expanduser() if path else config_home() / "umbriel" / "config.toml"


def expand_path(raw: str, base: Path) -> Path:
    value = os.path.expandvars(os.path.expanduser(raw))
    result = Path(value)
    return result if result.is_absolute() else base / result


def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def collect_keybinds(path: Path, seen: set[Path] | None = None) -> list[tuple[str, object, Path]]:
    seen = seen or set()
    path = path.resolve()
    if path in seen or not path.is_file():
        return []
    seen.add(path)
    data = load_toml(path)
    result: list[tuple[str, object, Path]] = []
    include = data.get("include", {}) if isinstance(data.get("include", {}), dict) else {}
    for raw in include.get("files", []) or []:
        result.extend(collect_keybinds(expand_path(str(raw), path.parent), seen))
    optional = include.get("optional", {}) if isinstance(include.get("optional", {}), dict) else {}
    for raw in optional.get("files", []) or []:
        child = expand_path(str(raw), path.parent)
        if child.is_file():
            result.extend(collect_keybinds(child, seen))
    table = data.get("keybinds", {})
    if isinstance(table, dict):
        for chord, value in table.items():
            result.append((str(chord), value, path))
    return result


def effective_keybinds(path: Path) -> list[dict]:
    merged: dict[str, dict] = {}
    order: list[str] = []
    for chord, value, source in collect_keybinds(path):
        if chord not in merged:
            order.append(chord)
        if isinstance(value, str):
            action = value
            options = {}
        elif isinstance(value, dict):
            action = str(value.get("action", ""))
            options = {k: v for k, v in value.items() if k != "action"}
        else:
            continue
        merged[chord] = {"action": action, "options": options, "source": source}
    return [{"chord": chord, **merged[chord]} for chord in order if merged[chord]["action"] != NEUTRAL_ACTION]


def mods_and_key(chord: str) -> tuple[list[str], str]:
    parts = chord.split("+")
    key = parts[-1] if parts else chord
    mods = [("Super" if part == "Mod" else part) for part in parts[:-1]]
    key = key.replace("Wheel", "Wheel ")
    if key.startswith("XF86Audio"):
        key = key.replace("XF86Audio", "").replace("RaiseVolume", "Vol+").replace("LowerVolume", "Vol-")
    elif key.startswith("XF86MonBrightness"):
        key = key.replace("XF86MonBrightness", "Brightness").replace("Up", "+").replace("Down", "-")
    elif key.startswith("XF86"):
        key = key.removeprefix("XF86")
    return mods, key


def parse_inir_action(action: str) -> tuple[str, str] | None:
    if not action.startswith("spawn:inir "):
        return None
    parts = action.removeprefix("spawn:inir ").split()
    if not parts:
        return None
    return parts[0], parts[1] if len(parts) > 1 else "open"


def description(action: str, chord: str) -> str:
    if action in DESCRIPTIONS:
        return DESCRIPTIONS[action]
    inir = parse_inir_action(action)
    if inir:
        if inir in IPC_DESCRIPTIONS:
            return IPC_DESCRIPTIONS[inir]
        if inir == ("terminal", "open"):
            return "Terminal"
        if inir == ("browser", "open"):
            return "Browser"
        if inir == ("close-window", "open"):
            return "Close window"
        return " ".join(inir)
    m = re.fullmatch(r"workspace-switch:(.+)", action)
    if m:
        return f"Focus workspace {m.group(1)}"
    m = re.fullmatch(r"column-move-to-workspace:(.+)", action)
    if m:
        return f"Move to workspace {m.group(1)}"
    m = re.fullmatch(r"window-modify-(width|height):([+-]?[0-9.]+)", action)
    if m:
        direction = "Grow" if not m.group(2).startswith("-") else "Shrink"
        return f"{direction} {'column' if m.group(1) == 'width' else 'window'}"
    if action.startswith("spawn:nautilus"):
        return "File manager"
    if chord == "Print":
        return "Screenshot menu"
    return action.replace("-", " ").replace(":", " ").strip().capitalize()


def category(action: str, chord: str) -> str:
    if chord.startswith("XF86") or " mpris " in f" {action} " or " audio " in f" {action} " or " brightness " in f" {action} ":
        return "Media & Hardware"
    if "Print" in chord or "screenshot" in action or "region" in action:
        return "Screenshots"
    if action.startswith("spawn:inir"):
        if any(token in action for token in (" terminal", " browser")) or action.startswith("spawn:nautilus"):
            return "Applications"
        return "iNiR Shell"
    if action.startswith("spawn:nautilus"):
        return "Applications"
    if action.startswith("workspace-") or "-workspace" in action:
        return "Workspaces"
    if action.startswith("output-") or "-output-" in action:
        return "Outputs"
    if action.startswith("window-") or action.startswith("column-"):
        return "Windows"
    if action in ("overview-toggle", "session-quit", "dpms-off", "dpms-on"):
        return "System"
    return "Other"


def option_string(options: dict) -> str:
    out = []
    for key in ("repeat", "allow_when_locked", "cooldown_ms"):
        if key not in options:
            continue
        label = key.replace("_", "-")
        value = options[key]
        out.append(f"{label}={'true' if value is True else 'false' if value is False else value}")
    return " ".join(out)


def build_models(path: Path) -> dict:
    rows = []
    groups: dict[str, list[int]] = {}
    for item in effective_keybinds(path):
        chord, action = item["chord"], item["action"]
        cat = category(action, chord)
        desc = description(action, chord)
        mods, key = mods_and_key(chord)
        idx = len(rows)
        rows.append({
            "key_combo": chord,
            "options": option_string(item["options"]),
            "action": action,
            "action_raw": action,
            "category": cat,
            "description": desc,
            "line_number": 0,
            "commented": False,
            "source": str(item["source"]),
            "mods": mods,
            "key": key,
        })
        groups.setdefault(cat, []).append(idx)
    preferred = ["System", "iNiR Shell", "Applications", "Windows", "Workspaces", "Outputs", "Screenshots", "Media & Hardware", "Other"]
    categories = [{"name": name, "binds": groups[name]} for name in preferred if name in groups]
    children = []
    for group in categories:
        keybinds = [{"mods": rows[i]["mods"], "key": rows[i]["key"], "action": rows[i]["action"], "comment": rows[i]["description"]} for i in group["binds"]]
        children.append({"name": group["name"], "children": [{"keybinds": keybinds}]})
    return {"binds": rows, "categories": categories, "children": children, "configPath": str(path)}


def managed_binds_path(path: Path) -> Path:
    candidate = path.parent / "config.d" / "70-binds.toml"
    if candidate.is_file():
        return candidate
    raise RuntimeError("iNiR-managed Umbriel keybind file not found: config.d/70-binds.toml")


def escape_toml(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def parse_options(raw: str) -> dict:
    result = {}
    for token in raw.split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        key = key.replace("-", "_")
        if key not in {"repeat", "allow_when_locked", "cooldown_ms"}:
            continue
        if value.lower() in {"true", "false"}:
            result[key] = value.lower() == "true"
        else:
            try:
                result[key] = int(value)
            except ValueError:
                pass
    return result


def render_bind(chord: str, action: str, options: dict) -> str:
    left = json.dumps(chord, ensure_ascii=False)
    if not options:
        return f"{left} = {json.dumps(action, ensure_ascii=False)}"
    fields = [f"action = {json.dumps(action, ensure_ascii=False)}"]
    for key in ("repeat", "allow_when_locked", "cooldown_ms"):
        if key not in options:
            continue
        value = options[key]
        rendered = "true" if value is True else "false" if value is False else str(value)
        fields.append(f"{key} = {rendered}")
    return f"{left} = {{ {', '.join(fields)} }}"


def replace_bind(path: Path, chord: str, line: str | None) -> None:
    text = path.read_text()
    pattern = re.compile(rf'^\s*{re.escape(json.dumps(chord))}\s*=.*$', re.MULTILINE)
    if pattern.search(text):
        text = pattern.sub(line or "", text, count=1)
    elif line:
        text = text.rstrip() + "\n" + line + "\n"
    path.write_text(text)



MANAGED_SECTION_FILES = {
    "general": "00-session.toml",
    "workspaces": "00-session.toml",
    "overview": "00-session.toml",
    "hot_corners": "00-session.toml",
    "input": "10-input.toml",
    "layout": "20-layout.toml",
    "appearance": "20-layout.toml",
    "colors": "20-layout.toml",
    "animation": "60-animations.toml",
}


def deep_merge(base: dict, incoming: dict) -> dict:
    out = dict(base)
    for key, value in incoming.items():
        if key == "include":
            continue
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def effective_config(path: Path, seen: set[Path] | None = None) -> dict:
    seen = seen or set()
    path = path.resolve()
    if path in seen or not path.is_file():
        return {}
    seen.add(path)
    data = load_toml(path)
    merged: dict = {}
    include = data.get("include", {}) if isinstance(data.get("include", {}), dict) else {}
    for raw in include.get("files", []) or []:
        merged = deep_merge(merged, effective_config(expand_path(str(raw), path.parent), seen))
    optional = include.get("optional", {}) if isinstance(include.get("optional", {}), dict) else {}
    for raw in optional.get("files", []) or []:
        child = expand_path(str(raw), path.parent)
        if child.is_file():
            merged = deep_merge(merged, effective_config(child, seen))
    return deep_merge(merged, data)


def managed_section_path(root: Path, dotted_path: str) -> Path:
    head = dotted_path.split(".", 1)[0]
    rel = MANAGED_SECTION_FILES.get(head)
    if not rel:
        raise RuntimeError(f"unsupported managed Umbriel setting: {dotted_path}")
    candidate = root.parent / "config.d" / rel
    if not candidate.is_file():
        raise RuntimeError(f"iNiR-managed Umbriel section not found: config.d/{rel}")
    return candidate


def render_toml_value(value) -> str:
    if value is None or isinstance(value, dict):
        raise RuntimeError("unsupported TOML setting value")
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(render_toml_value(item) for item in value) + "]"
    raise RuntimeError(f"unsupported TOML setting type: {type(value).__name__}")


def set_toml_value(path: Path, dotted_path: str, value) -> None:
    parts = dotted_path.split(".")
    if len(parts) < 2 or any(not part for part in parts):
        raise RuntimeError(f"invalid setting path: {dotted_path}")
    table = ".".join(parts[:-1])
    key = parts[-1]
    text = path.read_text(encoding="utf-8")
    header = f"[{table}]"
    header_match = re.search(rf"(?m)^\s*{re.escape(header)}\s*$", text)
    rendered = f"{key} = {render_toml_value(value)}"
    if not header_match:
        text = text.rstrip() + f"\n\n{header}\n{rendered}\n"
        path.write_text(text, encoding="utf-8")
        return
    section_start = header_match.end()
    next_header = re.search(r"(?m)^\s*\[\[?.+?\]\]?\s*$", text[section_start:])
    section_end = section_start + next_header.start() if next_header else len(text)
    section = text[section_start:section_end]
    key_pattern = re.compile(rf"(?m)^(\s*){re.escape(key)}\s*=.*$")
    if key_pattern.search(section):
        section = key_pattern.sub(lambda m: m.group(1) + rendered, section, count=1)
    else:
        prefix = "" if section.endswith("\n") else "\n"
        section = section + prefix + rendered + "\n"
    path.write_text(text[:section_start] + section + text[section_end:], encoding="utf-8")


def reload_umbriel() -> None:
    if not os.environ.get("UMBRIEL_SOCKET"):
        return
    proc = subprocess.run(["umbriel", "msg", "config-reload"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip() or "Umbriel config reload failed")


def config_payload(path: Path) -> dict:
    data = effective_config(path)
    return {
        "success": True,
        "configPath": str(path),
        "managed": (path.parent / "config.d").is_dir(),
        "config": data,
    }


def outputs_payload() -> dict:
    proc = subprocess.run(["umbriel", "outputs", "--json"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip() or "umbriel outputs failed")
    return {"success": True, "outputs": json.loads(proc.stdout or "[]")}


OUTPUT_PREVIEW_UNIT = "inir-umbriel-output-preview"
OUTPUT_KEYS = {"mode", "scale", "transform", "vrr", "direct_scanout", "tearing", "hdr", "sdr_white"}


def output_config_path(root: Path) -> Path:
    candidate = root.parent / "config.d" / "15-outputs.toml"
    if not candidate.is_file():
        raise RuntimeError("iNiR-managed Umbriel output file not found: config.d/15-outputs.toml")
    return candidate


def output_preview_paths() -> tuple[Path, Path]:
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "inir"
    cache.mkdir(parents=True, exist_ok=True)
    return cache / "umbriel-output-preview.toml", cache / "umbriel-output-preview.json"


def _output_header(name: str) -> str:
    return f"[output.{json.dumps(name, ensure_ascii=False)}]"


def set_output_value(path: Path, output_name: str, key: str, value) -> None:
    if key not in OUTPUT_KEYS:
        raise RuntimeError(f"unsupported Umbriel output setting: {key}")
    if not output_name.strip():
        raise RuntimeError("output name is required")
    text = path.read_text(encoding="utf-8")
    header = _output_header(output_name)
    match = re.search(rf"(?m)^\s*{re.escape(header)}\s*$", text)
    rendered = f"{key} = {render_toml_value(value)}"
    if not match:
        path.write_text(text.rstrip() + f"\n\n{header}\n{rendered}\n", encoding="utf-8")
        return
    start = match.end()
    next_header = re.search(r"(?m)^\s*\[\[?.+?\]\]?\s*$", text[start:])
    end = start + next_header.start() if next_header else len(text)
    section = text[start:end]
    pattern = re.compile(rf"(?m)^(\s*){re.escape(key)}\s*=.*$")
    if pattern.search(section):
        section = pattern.sub(lambda m: m.group(1) + rendered, section, count=1)
    else:
        section += ("" if section.endswith("\n") else "\n") + rendered + "\n"
    path.write_text(text[:start] + section + text[end:], encoding="utf-8")


def cancel_output_preview_timer() -> None:
    subprocess.run(
        ["systemctl", "--user", "stop", f"{OUTPUT_PREVIEW_UNIT}.timer", f"{OUTPUT_PREVIEW_UNIT}.service"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    subprocess.run(
        ["systemctl", "--user", "reset-failed", f"{OUTPUT_PREVIEW_UNIT}.timer", f"{OUTPUT_PREVIEW_UNIT}.service"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )


def schedule_output_preview_rollback(root: Path, seconds: int = 15) -> None:
    cancel_output_preview_timer()
    command = [
        "systemd-run", "--user", f"--unit={OUTPUT_PREVIEW_UNIT}", f"--on-active={seconds}s", "--timer-property=AccuracySec=1s", "--collect",
        sys.executable, str(Path(__file__).resolve()), "--config", str(root), "auto-revert-output-preview",
    ]
    proc = subprocess.run(command, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip() or "failed to schedule output rollback")


def preview_output(root: Path, output_name: str, key: str, value) -> dict:
    target = output_config_path(root)
    backup, metadata = output_preview_paths()
    created_backup = not backup.exists()
    if created_backup:
        backup.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
        metadata.write_text(json.dumps({"config": str(root), "target": str(target)}), encoding="utf-8")
    before = target.read_text(encoding="utf-8")
    try:
        set_output_value(target, output_name, key, value)
        validate(root)
        schedule_output_preview_rollback(root)
        reload_umbriel()
    except Exception:
        target.write_text(before, encoding="utf-8")
        if created_backup:
            backup.unlink(missing_ok=True)
            metadata.unlink(missing_ok=True)
        raise
    return {"success": True, "output": output_name, "key": key, "value": value, "timeout": 15}


def _restore_output_preview(root: Path) -> bool:
    target = output_config_path(root)
    backup, metadata = output_preview_paths()
    if not backup.exists():
        metadata.unlink(missing_ok=True)
        return False
    target.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")
    validate(root)
    reload_umbriel()
    backup.unlink(missing_ok=True)
    metadata.unlink(missing_ok=True)
    return True


def revert_output_preview(root: Path, cancel_timer: bool = True) -> dict:
    if cancel_timer:
        cancel_output_preview_timer()
    return {"success": True, "reverted": _restore_output_preview(root)}


def confirm_output_preview() -> dict:
    cancel_output_preview_timer()
    backup, metadata = output_preview_paths()
    confirmed = backup.exists()
    backup.unlink(missing_ok=True)
    metadata.unlink(missing_ok=True)
    return {"success": True, "confirmed": confirmed}


AUTOSTART_BEGIN = "# >>> inir-managed-autostart >>>"
AUTOSTART_END = "# <<< inir-managed-autostart <<<"
AUTOSTART_HEADER = "# Managed by iNiR Settings - entries apply on the next Umbriel login."


def autostart_path(root: Path) -> Path:
    candidate = root.parent / "config.d" / "50-startup.toml"
    if not candidate.is_file():
        raise RuntimeError("iNiR-managed Umbriel autostart file not found: config.d/50-startup.toml")
    return candidate


def _parse_toml_string_line(line: str) -> str | None:
    stripped = line.strip()
    if stripped.endswith(","):
        stripped = stripped[:-1].rstrip()
    if not stripped:
        return None
    try:
        value = tomllib.loads("value = " + stripped).get("value")
    except Exception:
        return None
    return value if isinstance(value, str) and value else None


def _command_tokens(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return [command]


def _entry_from_command(command: str, enabled: bool) -> dict:
    tokens = _command_tokens(command)
    if len(tokens) == 2 and tokens[0] == "gtk-launch":
        return {"type": "app", "desktopId": tokens[1], "enabled": enabled}
    return {"type": "command", "command": command, "enabled": enabled}


def _entry_command(entry: dict) -> str:
    if entry.get("type") == "app":
        desktop_id = str(entry.get("desktopId", "")).strip()
        if not desktop_id:
            raise RuntimeError("autostart app entry is missing desktopId")
        return "gtk-launch " + shlex.quote(desktop_id)
    command = str(entry.get("command", "")).strip()
    if not command:
        raise RuntimeError("autostart command entry is empty")
    return command


def _autostart_array_bounds(text: str) -> tuple[int, int, str]:
    lines = text.splitlines(keepends=True)
    offset = 0
    start = -1
    end = -1
    indent = "  "
    in_general = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_general = stripped == "[general]"
        if in_general and re.match(r"^\s*autostart\s*=\s*\[\s*$", line):
            start = offset + len(line)
            break
        offset += len(line)
    if start < 0:
        raise RuntimeError("managed Umbriel startup file needs a multi-line general.autostart array")

    pos = start
    for line in text[start:].splitlines(keepends=True):
        stripped = line.strip()
        if stripped == "]":
            end = pos
            break
        if stripped and not stripped.startswith("#"):
            indent_match = re.match(r"^(\s+)", line)
            if indent_match:
                indent = indent_match.group(1)
        pos += len(line)
    if end < 0:
        raise RuntimeError("unterminated general.autostart array")
    return start, end, indent


def read_autostart(root: Path) -> dict:
    path = autostart_path(root)
    text = path.read_text(encoding="utf-8")
    array_start, array_end, _ = _autostart_array_bounds(text)
    body = text[array_start:array_end]
    lines = body.splitlines()
    begin = next((i for i, line in enumerate(lines) if line.strip() == AUTOSTART_BEGIN), -1)
    end = next((i for i, line in enumerate(lines) if line.strip() == AUTOSTART_END), -1)
    if (begin >= 0) != (end >= 0) or (begin >= 0 and end <= begin):
        raise RuntimeError("Umbriel autostart markers are incomplete")

    entries: list[dict] = []
    external: list[dict] = []
    for i, raw in enumerate(lines):
        stripped = raw.strip()
        managed = begin >= 0 and begin < i < end
        if stripped in {AUTOSTART_BEGIN, AUTOSTART_END, AUTOSTART_HEADER} or not stripped:
            continue
        enabled = True
        value_line = stripped
        if value_line.startswith("#"):
            enabled = False
            value_line = value_line[1:].strip()
        command = _parse_toml_string_line(value_line)
        if not command:
            continue
        if managed:
            entries.append(_entry_from_command(command, enabled))
        elif enabled:
            tokens = _command_tokens(command)
            external.append({"tokens": tokens, "enabled": True, "raw": command})

    return {
        "success": True,
        "configPath": str(path),
        "managed": True,
        "entries": entries,
        "externalLines": external,
        "hasMarkers": begin >= 0,
    }


def write_autostart(root: Path, entries: list[dict]) -> dict:
    if not isinstance(entries, list):
        raise RuntimeError("autostart entries must be an array")
    path = autostart_path(root)
    before = path.read_text(encoding="utf-8")
    array_start, array_end, indent = _autostart_array_bounds(before)
    body = before[array_start:array_end]
    body_lines = body.splitlines(keepends=True)
    begin = next((i for i, line in enumerate(body_lines) if line.strip() == AUTOSTART_BEGIN), -1)
    end = next((i for i, line in enumerate(body_lines) if line.strip() == AUTOSTART_END), -1)
    if (begin >= 0) != (end >= 0) or (begin >= 0 and end <= begin):
        raise RuntimeError("Umbriel autostart markers are incomplete")

    rendered = [indent + AUTOSTART_BEGIN + "\n", indent + AUTOSTART_HEADER + "\n"]
    for entry in entries:
        if not isinstance(entry, dict):
            raise RuntimeError("invalid autostart entry")
        command = _entry_command(entry)
        line = json.dumps(command, ensure_ascii=False) + ","
        if entry.get("enabled", True) is not True:
            line = "# " + line
        rendered.append(indent + line + "\n")
    rendered.append(indent + AUTOSTART_END + "\n")

    if begin >= 0:
        body_lines[begin:end + 1] = rendered
        new_body = "".join(body_lines)
    else:
        prefix = body
        if prefix and not prefix.endswith("\n"):
            prefix += "\n"
        new_body = prefix + "".join(rendered)

    path.write_text(before[:array_start] + new_body + before[array_end:], encoding="utf-8")
    try:
        validate(root)
    except Exception:
        path.write_text(before, encoding="utf-8")
        raise
    return read_autostart(root)


USER_RULES_FILE = "config.d/35-user-window-rules.toml"
RULE_MATCH_KEYS = {"app_id", "title", "xdg_tag", "content_type", "is_focused", "at_startup"}
RULE_KEYS = {
    "default_output", "default_workspace", "default_fullscreen", "default_floating", "default_maximize",
    "default_maximize_to_edges", "default_focused", "default_pinned", "default_width", "default_height",
    "opacity", "blur", "blur_popups", "blur_ignore_alpha", "blur_optimized", "focus_on_activate",
    "vrr", "tearing", "hdr",
}


def user_rules_path(root: Path) -> Path:
    return root.parent / USER_RULES_FILE


def read_user_rules(root: Path) -> dict:
    path = user_rules_path(root)
    if not path.is_file():
        return {"success": True, "configPath": str(path), "rules": [], "managed": False}
    data = load_toml(path)
    rules = data.get("window_rule", [])
    if not isinstance(rules, list):
        raise RuntimeError("managed Umbriel window rules must be an array")
    return {"success": True, "configPath": str(path), "rules": rules, "managed": True}


def _validate_rule(rule: dict) -> None:
    if not isinstance(rule, dict):
        raise RuntimeError("window rule must be an object")
    match = rule.get("match", {})
    if not isinstance(match, dict):
        raise RuntimeError("window rule match must be an object")
    unknown_match = set(match) - RULE_MATCH_KEYS
    unknown_rule = set(rule) - RULE_KEYS - {"match"}
    if unknown_match:
        raise RuntimeError("unsupported Umbriel rule match: " + ", ".join(sorted(unknown_match)))
    if unknown_rule:
        raise RuntimeError("unsupported Umbriel rule setting: " + ", ".join(sorted(unknown_rule)))
    if not match:
        raise RuntimeError("user window rules require at least one match selector")


def render_user_rules(rules: list[dict]) -> str:
    lines = ["# User window rules managed by iNiR Settings.\n", "# Project defaults stay in 30-window-rules.toml.\n"]
    for rule in rules:
        _validate_rule(rule)
        lines.append("\n[[window_rule]]\n")
        for key, value in rule.get("match", {}).items():
            lines.append(f"match.{key} = {render_toml_value(value)}\n")
        for key, value in rule.items():
            if key == "match" or value is None:
                continue
            lines.append(f"{key} = {render_toml_value(value)}\n")
    return "".join(lines)


def write_user_rules(root: Path, rules: list[dict]) -> dict:
    if not isinstance(rules, list):
        raise RuntimeError("window rules must be an array")
    path = user_rules_path(root)
    if not path.is_file():
        raise RuntimeError("managed Umbriel user window-rule file is not installed")
    before = path.read_text(encoding="utf-8")
    path.write_text(render_user_rules(rules), encoding="utf-8")
    try:
        validate(root)
        reload_umbriel()
    except Exception:
        path.write_text(before, encoding="utf-8")
        raise
    return read_user_rules(root)


def ensure_user_rules(root: Path) -> dict:
    if not root.is_file():
        raise RuntimeError("Umbriel config.toml not found")
    before_root = root.read_text(encoding="utf-8")
    path = user_rules_path(root)
    existed = path.exists()
    before_rules = path.read_text(encoding="utf-8") if existed else ""
    include_line = f'  "{USER_RULES_FILE}",\n'
    if USER_RULES_FILE not in before_root:
        anchor = '  "config.d/30-window-rules.toml",\n'
        if anchor not in before_root or '  "config.d/40-environment.toml",\n' not in before_root:
            raise RuntimeError("Umbriel config is not using iNiR's managed include layout")
        root.write_text(before_root.replace(anchor, anchor + include_line, 1), encoding="utf-8")
    if not path.exists():
        path.write_text(render_user_rules([]), encoding="utf-8")
    try:
        validate(root)
    except Exception:
        root.write_text(before_root, encoding="utf-8")
        if existed:
            path.write_text(before_rules, encoding="utf-8")
        else:
            path.unlink(missing_ok=True)
        raise
    return {"success": True, "configPath": str(path), "installed": True}

def validate(path: Path) -> None:
    proc = subprocess.run(["umbriel", "validate", "-c", str(path)], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip() or "umbriel validate failed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("get-config")
    sub.add_parser("outputs")
    sub.add_parser("get-autostart")
    sub.add_parser("get-window-rules")
    setrules = sub.add_parser("set-window-rules")
    setrules.add_argument("rules")
    sub.add_parser("ensure-user-rules")
    setauto = sub.add_parser("set-autostart")
    setauto.add_argument("entries")
    setcfg = sub.add_parser("set")
    setcfg.add_argument("path")
    setcfg.add_argument("value")
    output_preview = sub.add_parser("preview-output")
    output_preview.add_argument("output")
    output_preview.add_argument("key")
    output_preview.add_argument("value")
    sub.add_parser("confirm-output-preview")
    sub.add_parser("revert-output-preview")
    sub.add_parser("auto-revert-output-preview")
    sub.add_parser("get-binds")
    setp = sub.add_parser("set-bind")
    setp.add_argument("key_combo")
    setp.add_argument("action")
    setp.add_argument("--options", default="")
    remp = sub.add_parser("remove-bind")
    remp.add_argument("key_combo")
    sub.add_parser("validate")
    args = parser.parse_args()
    root = root_config(args.config)
    try:
        if args.command == "get-config":
            read_root = root
            if not read_root.is_file():
                fallback = Path(__file__).resolve().parent.parent / "defaults" / "umbriel" / "config.toml"
                if fallback.is_file():
                    read_root = fallback
            print(json.dumps(config_payload(read_root)))
            return 0
        if args.command == "outputs":
            print(json.dumps(outputs_payload()))
            return 0
        if args.command == "get-autostart":
            print(json.dumps(read_autostart(root)))
            return 0
        if args.command == "get-window-rules":
            print(json.dumps(read_user_rules(root)))
            return 0
        if args.command == "set-window-rules":
            print(json.dumps(write_user_rules(root, json.loads(args.rules))))
            return 0
        if args.command == "ensure-user-rules":
            print(json.dumps(ensure_user_rules(root)))
            return 0
        if args.command == "set-autostart":
            entries = json.loads(args.entries)
            print(json.dumps(write_autostart(root, entries)))
            return 0
        if args.command == "set":
            target = managed_section_path(root, args.path)
            before = target.read_text(encoding="utf-8")
            value = json.loads(args.value)
            set_toml_value(target, args.path, value)
            try:
                validate(root)
                reload_umbriel()
            except Exception:
                target.write_text(before, encoding="utf-8")
                raise
            print(json.dumps({"success": True, "path": args.path, "value": value}))
            return 0
        if args.command == "preview-output":
            print(json.dumps(preview_output(root, args.output, args.key, json.loads(args.value))))
            return 0
        if args.command == "confirm-output-preview":
            print(json.dumps(confirm_output_preview()))
            return 0
        if args.command == "revert-output-preview":
            print(json.dumps(revert_output_preview(root, True)))
            return 0
        if args.command == "auto-revert-output-preview":
            print(json.dumps(revert_output_preview(root, False)))
            return 0
        if args.command == "get-binds":
            read_root = root
            if not read_root.is_file():
                fallback = Path(__file__).resolve().parent.parent / "defaults" / "umbriel" / "config.toml"
                if fallback.is_file():
                    read_root = fallback
            print(json.dumps(build_models(read_root)))
            return 0
        if args.command == "validate":
            validate(root)
            print(json.dumps({"success": True}))
            return 0
        binds = managed_binds_path(root)
        before = binds.read_text()
        if args.command == "set-bind":
            replace_bind(binds, args.key_combo, render_bind(args.key_combo, args.action, parse_options(args.options)))
        else:
            replacement = render_bind(args.key_combo, NEUTRAL_ACTION, {"repeat": False}) if args.key_combo in BUILTIN_CHORDS else None
            replace_bind(binds, args.key_combo, replacement)
        try:
            validate(root)
            reload_umbriel()
        except Exception:
            binds.write_text(before)
            raise
        print(json.dumps({"success": True, "key_combo": args.key_combo}))
        return 0
    except Exception as exc:
        print(json.dumps({"success": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
