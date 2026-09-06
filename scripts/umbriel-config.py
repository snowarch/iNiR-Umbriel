#!/usr/bin/env python3
import argparse
import json
import os
import re
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


def validate(path: Path) -> None:
    proc = subprocess.run(["umbriel", "validate", "-c", str(path)], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip() or "umbriel validate failed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command", required=True)
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
