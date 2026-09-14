#!/usr/bin/env python3
"""Pick the Omarchy keybinding worth learning right now.

Reads the usage log written by ~/.config/hypr/keyhints.lua, the annotated
binding list from `omarchy menu keybindings --print`, and the current Hyprland
state, then prints one hint as JSON for the bar widget.

  keyhints.py hint            JSON for the widget
  keyhints.py panel           JSON for the popup: hint, up next, most used
  keyhints.py stats           usage leaderboard and learned list
  keyhints.py next | prev     step the rotation
  keyhints.py learned <id>    mark a hint as known (left click)
  keyhints.py snooze <id>     hide a hint for a few hours (middle click)
  keyhints.py unlearn <id>    put a hint back in rotation
  keyhints.py reset           forget manual learned/snoozed state (keeps the log)
"""

import json
import os
import re
import subprocess
import sys
import time

STATE_DIR = os.path.expanduser("~/.local/state/omarchy/keyhints")
LOG_PATH = os.path.join(STATE_DIR, "usage.log")
STATE_PATH = os.path.join(STATE_DIR, "state.json")
TRACKER_PATH = os.path.expanduser("~/.config/hypr/keyhints.lua")

# A binding counts as learned once it has been used this much.
LEARNED_TOTAL = 15
LEARNED_RECENT = 5
RECENT_WINDOW = 7 * 86400

# How often the non-contextual hint rotates, and how many of the most
# important unlearned bindings take part in that rotation.
ROTATE_SECONDS = 600
ROTATION_POOL = 8
SNOOZE_SECONDS = 4 * 3600

MODS = {"SUPER", "SHIFT", "CTRL", "CONTROL", "ALT", "META"}
DIRECTIONS = {"LEFT", "RIGHT", "UP", "DOWN"}
DIR_RE = re.compile(
    r"\b(to the left|to the right|on the left|on the right|on top|on bottom|"
    r"on left|on right|left|right|up|down|above|below)\b",
    re.I,
)
NUM_RE = re.compile(r"\b(10|[0-9])\b")
ARROWS = "←↑↓→"

# Tidier names for collapsed families whose description reads oddly once the
# direction word is removed.
FAMILY_NAMES = {
    "Focus on window": "Focus window",
    "Move window to group on": "Move window into group",
    "Move workspace to monitor": "Move workspace to monitor",
    "Expand window": "Grow window",
    "Expand window a little": "Grow window a little",
    "Expand window a lot": "Grow window a lot",
}

# (regex on family description, tier, contexts). Lower tier = more important.
# Contexts: empty, single, multi, crowded, floating.
RULES = [
    (r"^Terminal$", 0, ["empty"]),
    (r"^Omarchy menu$", 0, ["empty"]),
    (r"^Keybindings$", 0, ["empty"]),
    (r"^Browser$", 0, ["empty"]),
    (r"^Apps menu$", 1, ["empty"]),
    (r"^File manager$", 1, ["empty"]),
    (r"^Close window$", 0, ["multi", "crowded"]),
    (r"^Focus window$", 0, ["multi"]),
    (r"^Swap window$", 0, ["multi"]),
    (r"^Toggle window split$", 1, ["multi"]),
    (r"^Full screen$", 1, ["single", "multi"]),
    (r"^Full width$", 1, ["multi"]),
    (r"^Toggle window floating", 1, ["single", "multi", "floating"]),
    (r"^Pop window out", 2, ["floating"]),
    (r"^Switch to workspace N$", 0, ["empty", "multi", "crowded"]),
    (r"^Move window to workspace N$", 0, ["multi", "crowded"]),
    (r"^(Next|Previous|Former) workspace$", 1, ["crowded"]),
    (r"^Move window silently", 3, ["crowded"]),
    (r"scratchpad", 2, ["crowded"]),
    (r"^Focus on (next|previous) window$", 1, ["multi"]),
    (r"^(Expand|Shrink) window", 2, ["multi"]),
    (r"^Universal (copy|paste|cut)$", 1, []),
    (r"^Clipboard manager$|^Emojis$", 2, []),
    (r"^Screenshot$|^Screenrecording$|^Color picker$|^Capture menu$", 2, []),
    (r"^System menu$|^Lock system$", 2, []),
    (r"^Toggle top bar$|^Theme menu$|^Background switcher$", 3, []),
    (r"notification", 3, []),
    (r"group", 3, ["crowded"]),
    (r"^Bar panel N$|^Audio$|^Bluetooth$|^Network$|^Display$|^Power$", 3, []),
    (r"^Tmux$|^Herdr$|keybindings$", 3, []),
]
DEFAULT_TIER = 4

CONTEXT_REASON = {
    "empty": "Empty workspace",
    "single": "One window open",
    "multi": "A few windows open",
    "crowded": "Busy workspace",
    "floating": "Floating window focused",
    "none": "Rotating tip",
}


def norm_keys(keys):
    tokens = [t for t in re.split(r"[\s+]+", keys.strip().upper()) if t]
    mods = sorted("CTRL" if t == "CONTROL" else t for t in tokens if t in MODS)
    rest = [t for t in tokens if t not in MODS]
    return "+".join(mods + rest)


def load_bindings():
    out = subprocess.run(
        ["omarchy-menu-keybindings", "--print"], capture_output=True, text=True
    ).stdout
    bindings = []
    for line in out.splitlines():
        if "→" not in line:
            continue
        keys, desc = line.split("→", 1)
        keys, desc = keys.strip(), desc.strip()
        if not keys or not desc:
            continue
        if "XF86" in keys or "MOUSE" in keys.upper():
            continue
        bindings.append((keys, desc))
    return bindings


def family_of(keys, desc):
    """Collapse numbered/directional variants into one family."""
    last = keys.split("+")[-1].strip().upper()
    if last.isdigit() and NUM_RE.search(desc):
        fam = NUM_RE.sub("N", desc)
        show_keys = re.sub(r"\b\d+$", "1-9", keys.strip())
    elif last in DIRECTIONS and DIR_RE.search(desc):
        fam = re.sub(r"\s+", " ", DIR_RE.sub("", desc)).strip()
        fam = FAMILY_NAMES.get(fam, fam)
        show_keys = re.sub(r"\b(LEFT|RIGHT|UP|DOWN)$", ARROWS, keys.strip())
    else:
        fam, show_keys = desc, keys.strip()
    return fam, show_keys


def classify(fam):
    for pattern, tier, contexts in RULES:
        if re.search(pattern, fam, re.I):
            return tier, contexts
    return DEFAULT_TIER, []


def build_families():
    families = {}
    order = 0
    for keys, desc in load_bindings():
        fam, show_keys = family_of(keys, desc)
        entry = families.get(fam)
        if entry is None:
            tier, contexts = classify(fam)
            entry = families[fam] = {
                "id": fam,
                "keys": show_keys,
                "desc": fam,
                "members": set(),
                "tier": tier,
                "contexts": contexts,
                "order": order,
                "total": 0,
                "recent": 0,
                "last_use": 0,
            }
            order += 1
        entry["members"].add(norm_keys(keys))
    return families


def apply_usage(families):
    by_member = {m: f for f in families.values() for m in f["members"]}
    cutoff = time.time() - RECENT_WINDOW
    try:
        with open(LOG_PATH) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                fam = by_member.get(norm_keys(parts[1]))
                if fam is None:
                    continue
                fam["total"] += 1
                try:
                    stamp = int(parts[0])
                except ValueError:
                    continue
                fam["last_use"] = max(fam["last_use"], stamp)
                if stamp >= cutoff:
                    fam["recent"] += 1
    except FileNotFoundError:
        pass


def load_state():
    try:
        with open(STATE_PATH) as fh:
            state = json.load(fh)
    except (FileNotFoundError, ValueError):
        state = {}
    state.setdefault("learned", [])
    state.setdefault("snoozed", {})
    state.setdefault("offset", 0)
    state.setdefault("shown", {})
    return state


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, STATE_PATH)


def is_learned(fam, state):
    return (
        fam["id"] in state["learned"]
        or fam["total"] >= LEARNED_TOTAL
        or fam["recent"] >= LEARNED_RECENT
    )


def hyprland_context():
    try:
        ws = json.loads(subprocess.run(
            ["hyprctl", "-j", "activeworkspace"], capture_output=True, text=True
        ).stdout or "{}")
        win = json.loads(subprocess.run(
            ["hyprctl", "-j", "activewindow"], capture_output=True, text=True
        ).stdout or "{}")
    except ValueError:
        return "none"
    windows = int(ws.get("windows", 0) or 0)
    if windows == 0:
        return "empty"
    if win.get("floating"):
        return "floating"
    if windows == 1:
        return "single"
    if windows <= 3:
        return "multi"
    return "crowded"


def select(families, state, now):
    """Return (pool, index, context, reason) for the current moment."""

    candidates = [
        f for f in families.values()
        if not is_learned(f, state) and state["snoozed"].get(f["id"], 0) < now
    ]
    candidates.sort(key=lambda f: (f["tier"], f["order"]))
    learned_count = sum(1 for f in families.values() if is_learned(f, state))

    context = hyprland_context()
    pool = [f for f in candidates if context in f["contexts"]][:ROTATION_POOL]
    reason = CONTEXT_REASON[context]
    if not pool:
        pool = candidates[:ROTATION_POOL]
        reason = CONTEXT_REASON["none"]
    if not pool:
        return [], 0, context, reason

    # Using the hint that is on screen moves the rotation along right away,
    # instead of waiting for the next time bucket or the learned threshold.
    shown = state["shown"]
    shown_fam = families.get(shown.get("id", ""))
    if shown_fam and shown_fam["last_use"] >= int(shown.get("at", 0)):
        state["offset"] += 1

    bucket = int(now // ROTATE_SECONDS)
    index = (bucket + state["offset"]) % len(pool)
    fam = pool[index]
    if fam["id"] != shown.get("id"):
        state["shown"] = {"id": fam["id"], "at": int(now)}
        save_state(state)
    elif shown_fam and shown_fam["last_use"] >= int(shown.get("at", 0)):
        # Only one candidate left in this pool; restart its clock so the
        # same press is not counted again on the next refresh.
        state["shown"] = {"id": fam["id"], "at": int(now)}
        save_state(state)
    return pool, index, context, reason


def hint_payload(fam, context, reason, learned_count, total):
    return {
        "id": fam["id"],
        "keys": fam["keys"],
        "desc": fam["desc"],
        "text": f"{fam['keys']}  →  {fam['desc']}",
        "context": context,
        "reason": reason,
        "tier": fam["tier"],
        "uses": fam["total"],
        "learned": learned_count,
        "total": total,
    }


def learned_total(families, state):
    return sum(1 for f in families.values() if is_learned(f, state))


def pick_hint():
    families = build_families()
    apply_usage(families)
    state = load_state()
    now = time.time()
    pool, index, context, reason = select(families, state, now)
    learned_count = learned_total(families, state)
    if not pool:
        return {"text": "", "id": "", "learned": learned_count, "total": len(families)}
    return hint_payload(pool[index], context, reason, learned_count, len(families))


def panel_payload():
    families = build_families()
    apply_usage(families)
    state = load_state()
    now = time.time()
    pool, index, context, reason = select(families, state, now)
    learned_count = learned_total(families, state)
    total = len(families)

    hint = hint_payload(pool[index], context, reason, learned_count, total) if pool else None
    up_next = [
        {"keys": f["keys"], "desc": f["desc"]}
        for f in (pool[index + 1:] + pool[:index])[:5]
    ]
    used = sorted(
        (f for f in families.values() if f["total"] > 0),
        key=lambda f: (-f["total"], -f["last_use"]),
    )
    most_used = [
        {"keys": f["keys"], "desc": f["desc"], "uses": f["total"],
         "learned": is_learned(f, state)}
        for f in used[:8]
    ]
    return {
        "hint": hint,
        "up_next": up_next,
        "most_used": most_used,
        "learned": learned_count,
        "total": total,
        "presses": sum(f["total"] for f in families.values()),
        "tracker": os.path.exists(TRACKER_PATH),
    }


def stats():
    families = build_families()
    apply_usage(families)
    state = load_state()
    used = sorted(families.values(), key=lambda f: -f["total"])
    print("Most used:")
    for f in used[:15]:
        if f["total"] == 0:
            break
        flag = " (learned)" if is_learned(f, state) else ""
        print(f"  {f['total']:4d}  {f['keys']:28s} {f['desc']}{flag}")
    learned = [f for f in families.values() if is_learned(f, state)]
    print(f"\nLearned {len(learned)} of {len(families)} binding families.")
    if state["learned"]:
        print("Marked learned by hand:", ", ".join(state["learned"]))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "hint"
    if cmd == "hint":
        print(json.dumps(pick_hint()))
    elif cmd == "panel":
        print(json.dumps(panel_payload()))
    elif cmd in ("next", "prev"):
        state = load_state()
        state["offset"] += 1 if cmd == "next" else -1
        save_state(state)
    elif cmd == "stats":
        stats()
    elif cmd in ("learned", "snooze", "unlearn") and len(argv) > 2:
        state = load_state()
        fam_id = argv[2]
        if cmd == "learned" and fam_id not in state["learned"]:
            state["learned"].append(fam_id)
        elif cmd == "snooze":
            state["snoozed"][fam_id] = time.time() + SNOOZE_SECONDS
        elif cmd == "unlearn":
            state["learned"] = [x for x in state["learned"] if x != fam_id]
        save_state(state)
    elif cmd == "reset":
        save_state({"learned": [], "snoozed": {}, "offset": 0, "shown": {}})
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
