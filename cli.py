# SETUP: .\setup-python.ps1
# RUN:
#     python cli.py bot
#     python cli.py purge
#     python cli.py autoshow
#     python cli.py snap
#     python cli.py path\to\custom.yaml
#     python cli.py bot -d -v
# STOP: Ctrl+C or lose focus.

import argparse
import sys
import time
import logging
import ctypes
import ctypes.wintypes
from pathlib import Path
from datetime import datetime

import yaml
import numpy as np
import cv2
import mss
import pydirectinput

# =============================================================================
# Config
# =============================================================================
_ROOT = Path(__file__).resolve().parent

with open(_ROOT / "config.yaml") as _f:
    _cfg = yaml.safe_load(_f)

with open(_ROOT / "templates" / "thresholds.yaml") as _f:
    TEMPLATE_THRESHOLDS = yaml.safe_load(_f)

WINDOW_TITLE = _cfg["window_title"]
REFRAME_INTERVAL = float(_cfg["reframe_interval"])
KEY_INTERVAL = float(_cfg["key_interval"])
POLL_INTERVAL = float(_cfg["poll_interval"])
VERIFY_TIMEOUT = float(_cfg["verify_timeout"])

_grid = _cfg["grid"]
CENTER_X_C0 = float(_grid["center_x_c0"])
CENTER_Y_R0 = float(_grid["center_y_r0"])
COL_X_STEP = float(_grid["col_x_step"])
ROW_Y_STEP = float(_grid["row_y_step"])
SLOT_HALF_W = float(_grid["slot_half_w"])
SLOT_HALF_H = float(_grid["slot_half_h"])

_edge = _cfg["edge"]
EDGE_STDDEV_THRESHOLD = float(_edge["stddev_threshold"])
EDGE_WIDTH_FRAC = float(_edge["width_frac"])

TEMPLATES_DIR = _ROOT / "templates"
CAPTURE_RETRIES = 5
YELLOW_LOWER = np.array([20, 200, 200], dtype=np.uint8)
YELLOW_UPPER = np.array([32, 255, 255], dtype=np.uint8)
FOCUS_LOWER = np.array([35, 150, 150], dtype=np.uint8)
FOCUS_UPPER = np.array([75, 255, 255], dtype=np.uint8)


# =============================================================================
# Logging
# =============================================================================
_current_step = None
_logger = logging.getLogger("forza")


class _Formatter(logging.Formatter):
    def format(self, record):
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        level = record.levelname.ljust(7)
        prefix = f"[{_current_step}] " if _current_step else ""
        return f"{ts} {level} {prefix}{record.getMessage()}"


def log_setup(verbose=False, log_file=None):
    level = logging.DEBUG if verbose else logging.INFO
    _logger.setLevel(level)

    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(level)
    handler.setFormatter(_Formatter())
    _logger.addHandler(handler)

    if log_file:
        fh = logging.FileHandler(log_file, encoding="utf-8")
        fh.setLevel(level)
        fh.setFormatter(_Formatter())
        _logger.addHandler(fh)


def log_set_step(name):
    global _current_step
    _current_step = name


def log_info(msg):
    _logger.info(msg)


def log_debug(msg):
    _logger.debug(msg)


def is_debug_enabled():
    return _logger.isEnabledFor(logging.DEBUG)


def log_warning(msg):
    _logger.warning(msg)


def log_error(msg):
    _logger.error(msg)


# =============================================================================
# Window
# =============================================================================
_user32 = ctypes.windll.user32
_hwnd = None
_dpi_aware_set = False
_last_screen = None


class _RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


class _POINT(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_long),
        ("y", ctypes.c_long),
    ]


class _MONITORINFO(ctypes.Structure):
    _fields_ = [
        ("cbSize", ctypes.c_uint),
        ("rcMonitor", _RECT),
        ("rcWork", _RECT),
        ("dwFlags", ctypes.c_uint),
    ]


_WNDENUMPROC = ctypes.WINFUNCTYPE(
    ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM
)


def ensure_dpi_aware():
    global _dpi_aware_set
    if not _dpi_aware_set:
        try:
            _user32.SetProcessDPIAware()
        except Exception:
            pass

        _dpi_aware_set = True


def get_window_title(hwnd):
    length = _user32.GetWindowTextLengthW(hwnd)
    if length == 0:
        return ""

    buf = ctypes.create_unicode_buffer(length + 1)
    _user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def get_game_window():
    global _hwnd
    if _hwnd is None:
        matches = []

        def enum_window(hwnd, _):
            if WINDOW_TITLE in get_window_title(hwnd):
                matches.append(hwnd)
                return False
            return True

        _user32.EnumWindows(_WNDENUMPROC(enum_window), 0)
        if matches:
            _hwnd = matches[0]

    return _hwnd


def is_window_focused():
    try:
        fg = _user32.GetForegroundWindow()
        if not fg:
            return False

        return WINDOW_TITLE in get_window_title(fg)
    except Exception:
        return False


def get_monitor_size(hwnd):
    global _last_screen
    hmon = _user32.MonitorFromWindow(hwnd, 2)
    mi = _MONITORINFO()
    mi.cbSize = ctypes.sizeof(_MONITORINFO)
    _user32.GetMonitorInfoW(hmon, ctypes.byref(mi))

    w = mi.rcMonitor.right - mi.rcMonitor.left
    h = mi.rcMonitor.bottom - mi.rcMonitor.top

    if _last_screen != (w, h):
        log_info(f"Game window on monitor {w}x{h}")
        _last_screen = (w, h)

    return w, h


def get_client_rect(hwnd):
    r = _RECT()
    _user32.GetClientRect(hwnd, ctypes.byref(r))

    pt = _POINT(0, 0)
    _user32.ClientToScreen(hwnd, ctypes.byref(pt))

    return pt.x, pt.y, r.right - r.left, r.bottom - r.top


# =============================================================================
# Common helpers
# =============================================================================
def wait_for_refresh(seconds=None):
    if seconds is None:
        seconds = REFRAME_INTERVAL

    time.sleep(seconds)


def wait_poll_tick():
    time.sleep(POLL_INTERVAL)


def wait_countdown(seconds, label="Starting"):
    full = int(seconds)
    for r in range(full, 0, -1):
        print(f"{label} in {r}...")
        time.sleep(1)

    tail = seconds - full
    if tail > 0:
        time.sleep(tail)


# =============================================================================
# Input
# =============================================================================
pydirectinput.PAUSE = 0.02

_VK_MAP = {
    "W": 0x57,
    "SPACE": 0x20,
}

_KEYEVENTF_KEYUP = 0x0002


def key_press(key):
    log_debug(f"press {key}")
    pydirectinput.press(key)
    time.sleep(KEY_INTERVAL)


def key_repeat(key, times):
    for _ in range(times):
        key_press(key)


def hold_key(key):
    vk = _VK_MAP.get(key.upper())
    if vk:
        _user32.keybd_event(vk, 0, 0, ctypes.c_ulong(0))
    else:
        pydirectinput.keyDown(key)

    wait_poll_tick()


def release_key(key):
    vk = _VK_MAP.get(key.upper())
    if vk:
        _user32.keybd_event(vk, 0, _KEYEVENTF_KEYUP, ctypes.c_ulong(0))
    else:
        pydirectinput.keyUp(key)


def is_key_held(key):
    vk = _VK_MAP.get(key.upper())
    if vk is None:
        return True

    return (_user32.GetAsyncKeyState(vk) & 0x8000) != 0


# =============================================================================
# Screen capture
# =============================================================================
_sct = None


def capture_frame(wait=None):
    global _sct

    if wait is None:
        wait = REFRAME_INTERVAL

    if wait > 0:
        wait_for_refresh(wait)

    ensure_dpi_aware()
    hwnd = get_game_window()
    get_monitor_size(hwnd)
    cx, cy, cw, ch = get_client_rect(hwnd)
    region = {"top": cy, "left": cx, "width": cw, "height": ch}

    if _sct is None:
        _sct = mss.mss()

    last_err = None
    for att in range(CAPTURE_RETRIES):
        try:
            shot = _sct.grab(region)
            img = np.array(shot, dtype=np.uint8)
            bgr = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
            return bgr
        except Exception as e:
            last_err = e
            log_warning(
                f"Capture attempt {att + 1}/{CAPTURE_RETRIES} failed: {last_err}"
            )
            time.sleep(POLL_INTERVAL)

    raise RuntimeError(f"capture failed after {CAPTURE_RETRIES} attempts: {last_err}")


# =============================================================================
# Template loading + matching
# =============================================================================
_templates = {}
_scaled_cache = {}


def load_template(name):
    if name not in _templates:
        if name not in TEMPLATE_THRESHOLDS:
            log_error(f"Template '{name}' not found in thresholds.yaml")
            raise SystemExit(1)

        path = TEMPLATES_DIR / f"t_{name}.png"
        if not path.exists():
            log_error(f"Template file not found: {path}")
            raise SystemExit(1)

        _templates[name] = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)

    return _templates[name]


def get_threshold(name):
    if name not in TEMPLATE_THRESHOLDS:
        log_error(f"No template '{name}'")
        raise SystemExit(1)

    return float(TEMPLATE_THRESHOLDS[name])


def get_scaled(name, frame_w):
    key = (name, frame_w)
    if key in _scaled_cache:
        return _scaled_cache[key]

    tmpl = load_template(name)
    scale = frame_w / 1280.0

    if abs(scale - 1.0) < 0.01:
        _scaled_cache[key] = tmpl
        return tmpl

    nh = max(1, round(tmpl.shape[0] * scale))
    nw = max(1, round(tmpl.shape[1] * scale))

    if scale < 1.0:
        interp = cv2.INTER_AREA
    else:
        interp = cv2.INTER_LINEAR

    resized = cv2.resize(tmpl, (nw, nh), interpolation=interp)
    _scaled_cache[key] = resized
    return resized


def get_match_score(region_gray, name, frame_w=0):
    if frame_w == 0:
        frame_w = region_gray.shape[1]

    tmpl = get_scaled(name, frame_w)

    if tmpl.shape[0] > region_gray.shape[0] or tmpl.shape[1] > region_gray.shape[1]:
        return 0.0

    res = cv2.matchTemplate(region_gray, tmpl, cv2.TM_CCOEFF_NORMED)
    _, mx, _, _ = cv2.minMaxLoc(res)
    return mx


def match_template(gray, name, frame_w=0):
    score = get_match_score(gray, name, frame_w)
    return {"score": score, "matched": score > get_threshold(name)}


def format_template_expr(expr):
    if isinstance(expr, str):
        return expr

    keys = list(expr.keys())
    op = keys[0]
    items = expr[op]

    joiner = " and " if op == "all" else " or "
    return "(" + joiner.join(format_template_expr(item) for item in items) + ")"


def eval_template_expr(gray, expr, debug=False, frame_w=0):
    if isinstance(expr, str):
        r = match_template(gray, expr, frame_w)
        return {
            "matched": r["matched"],
            "details": [template_detail(expr, r)],
        }

    keys = list(expr.keys())
    op = keys[0]
    items = expr[op]

    details = []
    matched = op == "all"
    for item in items:
        r = eval_template_expr(gray, item, debug=debug, frame_w=frame_w)
        details.extend(r["details"])
        if op == "all":
            matched = matched and r["matched"]
            if not matched and not debug:
                break
        else:
            matched = matched or r["matched"]
            if matched and not debug:
                break

    return {"matched": matched, "details": details}


def template_detail(name, result):
    return {"name": name, "score": result["score"], "matched": result["matched"]}


def format_template_details(details):
    return ", ".join(
        f"{d['name']}:{'hit' if d['matched'] else 'miss'}({d['score']:.3f})"
        for d in details
    )


def template_tag(label):
    tag = "".join(ch if ch.isalnum() or ch in "_-" else "_" for ch in label)
    tag = tag.strip("_")
    return tag[:80] if tag else "match"


# =============================================================================
# Dump
# =============================================================================
_dump_dir = None
_dump_enabled = False


def dump_set_mode(enabled):
    global _dump_enabled
    _dump_enabled = enabled


def dump_is_enabled():
    return _dump_enabled


def dump_ensure_dir():
    global _dump_dir
    if _dump_dir is None:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        _dump_dir = _ROOT / f"{ts}_dump"

    _dump_dir.mkdir(parents=True, exist_ok=True)


def dump_get_dir():
    dump_ensure_dir()
    return _dump_dir


def dump_save_cells(cells, tag):
    if not _dump_enabled:
        return

    dump_ensure_dir()
    for c in range(4):
        for r in range(3):
            cell = cells[c][r]
            cv2.imwrite(str(_dump_dir / f"{tag}_c{c}r{r}_slot.png"), cell["bgr"])
            cv2.imwrite(
                str(_dump_dir / f"{tag}_c{c}r{r}_brand_new.png"), cell["yellow_bgr"]
            )


def dump_diagnostics(frame, tag):
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    dump_ensure_dir()
    p = _dump_dir / f"stuck_{tag}_{int(time.time())}.png"
    cv2.imwrite(str(p), frame)
    log_warning(f"Stuck ({tag}) -- frame saved to {p.name}")
    log_warning("Template scores:")

    for name, th_val in TEMPLATE_THRESHOLDS.items():
        sc = get_match_score(gray, name)
        th = float(th_val)

        if sc > th:
            mark = " ABOVE"
        else:
            mark = ""

        log_warning(f"  {name:<16s} = {sc:.3f} (th={th:.2f}){mark}")


# =============================================================================
# Grid
# =============================================================================
def get_scaled_slot(h, w, col, row):
    cx = (CENTER_X_C0 + col * COL_X_STEP) * w
    cy = (CENTER_Y_R0 + row * ROW_Y_STEP) * h
    hw = SLOT_HALF_W * w
    hh = SLOT_HALF_H * h
    return int(cx - hw), int(cy - hh), int(cx + hw), int(cy + hh)


def get_focus_edge_hits(frame, x0, y0, x1, y1):
    cx = (x0 + x1) // 2
    cy = (y0 + y1) // 2
    probe_len = max(2, int(max(x1 - x0, y1 - y0) * 0.06))

    lines = [
        frame[y0 : y0 + probe_len, cx : cx + 1],
        frame[y1 - probe_len : y1, cx : cx + 1],
        frame[cy : cy + 1, x0 : x0 + probe_len],
        frame[cy : cy + 1, x1 - probe_len : x1],
    ]

    hits = []
    for line in lines:
        hsv = cv2.cvtColor(line, cv2.COLOR_BGR2HSV)
        mask = cv2.inRange(hsv, FOCUS_LOWER, FOCUS_UPPER)
        hits.append(cv2.countNonZero(mask))

    return tuple(hits)


def is_slot_focused(hits):
    return sum(1 for h in hits if h > 0) >= 3


def get_grid_cells(frame):
    h, w = frame.shape[:2]
    slot_w = int(2 * SLOT_HALF_W * w)
    slot_h = int(2 * SLOT_HALF_H * h)
    y_lo = int(slot_h * 0.70)
    y_hi = int(slot_h * 0.82)
    x_lo = int(slot_w * 0.78)
    x_hi = int(slot_w * 0.98)

    cells = [[None] * 3 for _ in range(4)]
    focused = None

    for col in range(4):
        for row in range(3):
            x0, y0, x1, y1 = get_scaled_slot(h, w, col, row)
            bgr = frame[y0:y1, x0:x1].copy()
            gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
            yellow_bgr = frame[y0 + y_lo : y0 + y_hi, x0 + x_lo : x0 + x_hi].copy()

            cells[col][row] = {
                "bgr": bgr,
                "gray": gray,
                "yellow_bgr": yellow_bgr,
            }

            hits = get_focus_edge_hits(frame, x0, y0, x1, y1)
            is_foc = is_slot_focused(hits)
            if is_debug_enabled():
                foc_tag = " <- FOCUS" if is_foc else ""
                log_debug(
                    f"slot c{col}r{row} slot={x1 - x0}x{y1 - y0} hits={','.join(str(h) for h in hits)}{foc_tag}"
                )

            if is_foc and focused is None:
                focused = (col, row)

    return {"cells": cells, "focused": focused}


def is_brand_new(cell):
    hsv = cv2.cvtColor(cell["yellow_bgr"], cv2.COLOR_BGR2HSV)
    mask = cv2.inRange(hsv, YELLOW_LOWER, YELLOW_UPPER)
    return cv2.countNonZero(mask) > 0


def slice_grid(frame):
    grid = get_grid_cells(frame)

    if grid["focused"] is None:
        h, w = frame.shape[:2]
        log_warning("No focused slot detected; per-slot edge hits (T,B,L,R):")
        for col in range(4):
            for row in range(3):
                s = get_scaled_slot(h, w, col, row)
                hits = get_focus_edge_hits(frame, *s)
                log_warning(
                    f"  c{col}r{row} hits={','.join(str(h) for h in hits)} (focused={is_slot_focused(hits)})"
                )

        dump_ensure_dir()
        p = dump_get_dir() / f"no_focus_{int(time.time())}.png"
        cv2.imwrite(str(p), frame)
        log_warning(f"Frame saved to {p.name}")
        log_error("Stopping")
        raise SystemExit(1)

    return {
        "frame": frame,
        "cells": grid["cells"],
        "focused": grid["focused"],
    }


# =============================================================================
# Navigation
# =============================================================================
def move_cursor(from_pos, to_pos):
    dr = to_pos[1] - from_pos[1]
    if dr > 0:
        key_repeat("down", abs(dr))
    elif dr < 0:
        key_repeat("up", abs(dr))

    dc = to_pos[0] - from_pos[0]
    if dc > 0:
        key_repeat("right", abs(dc))
    elif dc < 0:
        key_repeat("left", abs(dc))


def is_edge_empty(gray, side):
    h, w = gray.shape[:2]
    ey0 = int((CENTER_Y_R0 - SLOT_HALF_H * 0.90) * h)
    ey1 = int((CENTER_Y_R0 + SLOT_HALF_H * 0.90) * h)
    ew = int(w * EDGE_WIDTH_FRAC)

    if side == "left":
        strip = gray[ey0:ey1, 0:ew]
    else:
        strip = gray[ey0:ey1, w - ew : w]

    mean, stddev = cv2.meanStdDev(strip)
    empty = stddev[0][0] < EDGE_STDDEV_THRESHOLD
    if is_debug_enabled():
        log_debug(
            f"is_edge_empty: side={side} stddev={stddev[0][0]:.1f} threshold={EDGE_STDDEV_THRESHOLD} empty={empty}"
        )
    return empty


def find_template_columns(gray, template):
    h, w = gray.shape[:2]
    tmpl = get_scaled(template, w)
    tw = tmpl.shape[1]

    crop_x = int((CENTER_X_C0 - SLOT_HALF_W) * w)
    crop_y = int((CENTER_Y_R0 - SLOT_HALF_H) * h)
    crop_r = int(0.95 * w)
    crop_b = int(0.90 * h)
    roi = gray[crop_y:crop_b, crop_x:crop_r]

    res = cv2.matchTemplate(roi, tmpl, cv2.TM_CCOEFF_NORMED)
    _, mask = cv2.threshold(res, get_threshold(template), 1.0, cv2.THRESH_BINARY)
    mask8 = (mask * 255).astype(np.uint8)
    locs = cv2.findNonZero(mask8)

    count = 0 if locs is None else len(locs)
    raw_hits = []
    merge_width = tw / float(w)
    for i in range(count):
        px = locs[i][0][0]
        cx = (px + tw / 2.0 + crop_x) / w
        raw_hits.append(cx)

    hits = []
    for cx in sorted(raw_hits):
        if not hits or abs(cx - hits[-1]) >= merge_width:
            hits.append(cx)

    if is_debug_enabled():
        log_debug(
            f"find_template_columns: template={template} frame={w}x{h} tmpl={tw}x{tmpl.shape[0]} "
            f"raw_count={count} merged={len(hits)} xfracs=[{', '.join(f'{x:.4f}' for x in hits)}]"
        )

    return hits


def get_template_column(x_frac):
    return round((x_frac - CENTER_X_C0) / COL_X_STEP)


def analyze_frame(frame, template, edge_side=None):
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    template_cols = find_template_columns(gray, template)
    is_first = is_edge_empty(gray, "left") if edge_side in (None, "left") else None
    is_last = is_edge_empty(gray, "right") if edge_side in (None, "right") else None
    return template_cols, is_first, is_last


def scroll_left_to(template):
    log_info("scanning left")
    lefts = 0

    while True:
        frame = capture_frame()
        template_cols, is_first, _ = analyze_frame(frame, template, edge_side="left")
        log_debug(
            f"left scan: matches={len(template_cols)} first_page={is_first} lefts={lefts}"
        )

        if len(template_cols) > 0:
            col = get_template_column(template_cols[0])

            if col > 0:
                log_info(f"match at c{col}, right {col}")
                key_repeat("right", col)
                return 0

            if is_first:
                log_info("match at c0, first page")
                return 0
        else:
            if is_first:
                log_info(f"first page, no match (lefts={lefts})")
                return lefts

        key_press("left")
        lefts += 1


def scroll_right_to(template):
    log_info("scanning right")

    while True:
        frame = capture_frame()
        template_cols, _, is_last = analyze_frame(frame, template, edge_side="right")
        log_debug(f"right scan: matches={len(template_cols)} last_page={is_last}")

        if len(template_cols) > 0:
            col = get_template_column(template_cols[0])
            if col > 0:
                key_repeat("right", col)
                log_info("match at c0")
                return {"frame": None}

            log_info("match at c0")
            return {"frame": frame}

        if is_last:
            log_info("last page, no match found")
            return None

        key_repeat("right", 4)


def scroll_to(template):
    log_info(f"scroll_to template={template}")
    lefts = scroll_left_to(template)

    if lefts == 0:
        return 0

    log_info(f"right {lefts} to return")
    key_repeat("right", lefts)
    return scroll_right_to(template)


# =============================================================================
# Purge
# =============================================================================
def brand_new_condition_passes(is_new, brand_new_filter):
    return brand_new_filter is None or is_new == brand_new_filter


def describe_brand_new(brand_new_filter):
    if brand_new_filter is None:
        return "bypass"
    return str(brand_new_filter).lower()


def describe_marker(marker):
    return marker if marker else "bypass"


def _purge_candidate(cells, frame_w, template, marker, brand_new_filter, focused):
    candidate = None
    focused_is_candidate = False
    debug = is_debug_enabled()

    for col in range(4):
        for row in range(3):
            cell = cells[col][row]
            template_result = match_template(cell["gray"], template, frame_w)
            marker_result = None
            new = None

            if template_result["matched"]:
                if marker is None:
                    marker_matches = True
                else:
                    marker_result = match_template(cell["gray"], marker, frame_w)
                    marker_matches = marker_result["matched"]

                if brand_new_filter is None:
                    brand_new_matches = True
                else:
                    new = is_brand_new(cell)
                    brand_new_matches = brand_new_condition_passes(
                        new, brand_new_filter
                    )
                is_candidate = marker_matches and brand_new_matches

                if debug:
                    new_label = "n/a" if new is None else str(new)
                    marker_label = (
                        "n/a"
                        if marker_result is None
                        else format_template_details(
                            [template_detail(marker, marker_result)]
                        )
                    )
                    log_debug(
                        f"slot c{col}r{row} template={template}={template_result['score']:.3f}:hit marker={marker_label} brand_new={new_label} candidate={is_candidate}"
                    )

                if is_candidate:
                    pos = (col, row)
                    if pos == focused:
                        candidate = pos
                        focused_is_candidate = True
                    elif candidate is None:
                        candidate = pos

            elif debug:
                log_debug(
                    f"slot c{col}r{row} template={template}={template_result['score']:.3f}:miss marker=n/a brand_new=n/a candidate=False"
                )

    return {
        "candidate": candidate,
        "focused_is_candidate": focused_is_candidate,
    }


# =============================================================================
# Workflow validation
# =============================================================================
def validate_template_expr(action, expr):
    if isinstance(expr, str):
        if expr == "":
            log_error(f"{action} template must not be empty")
            raise SystemExit(1)
        return

    if isinstance(expr, list):
        log_error(f"{action} template lists must be under all or any")
        raise SystemExit(1)

    if not isinstance(expr, dict):
        log_error(f"{action} template must be a template name or an all/any expression")
        raise SystemExit(1)

    keys = list(expr.keys())
    if len(keys) != 1 or keys[0] not in ("all", "any"):
        log_error(
            f"{action} template expression must contain exactly one key: all or any"
        )
        raise SystemExit(1)

    op = keys[0]
    items = expr[op]
    if not isinstance(items, list) or not items:
        log_error(f"{action} template {op} expression must be a non-empty list")
        raise SystemExit(1)

    for item in items:
        validate_template_expr(action, item)


def read_template_expr(action, value):
    if not isinstance(value, dict):
        log_error(f"{action} requires a mapping with template")
        raise SystemExit(1)

    if "match" in value:
        log_error(f"{action} uses template, not match")
        raise SystemExit(1)

    if "template" not in value:
        log_error(f"{action} requires template")
        raise SystemExit(1)

    validate_template_expr(action, value["template"])
    return value["template"]


def read_template(action, value):
    if not isinstance(value, str):
        log_error(f"{action} requires a single template name")
        raise SystemExit(1)

    return value


def read_mapping_template(action, value):
    if not isinstance(value, dict):
        log_error(f"{action} requires a mapping with template")
        raise SystemExit(1)

    if "match" in value:
        log_error(f"{action} uses template, not match")
        raise SystemExit(1)

    if "template" not in value:
        log_error(f"{action} requires template")
        raise SystemExit(1)

    if not isinstance(value["template"], str):
        log_error(f"{action} template must be a single template name")
        raise SystemExit(1)

    return value["template"]


def read_marker(action, value):
    if not isinstance(value, dict) or "marker" not in value or value["marker"] is None:
        return None

    if not isinstance(value["marker"], str):
        log_error(f"{action} marker must be a single template name")
        raise SystemExit(1)

    return value["marker"]


def read_brand_new(action, value):
    if not isinstance(value, dict):
        log_error(f"{action} requires a mapping with brand_new")
        raise SystemExit(1)

    if "brand_new" not in value or value["brand_new"] is None:
        log_error(f"{action} requires brand_new: true, false, or bypass")
        raise SystemExit(1)

    brand_new = value["brand_new"]
    if isinstance(brand_new, bool):
        return brand_new

    if isinstance(brand_new, str) and brand_new.lower() == "bypass":
        return None

    log_error(f"{action} brand_new must be true, false, or bypass")
    raise SystemExit(1)


def validate_number(action, value, field="value", integer=False, allow_empty=False):
    if value is None or str(value) == "":
        if allow_empty:
            return
        log_error(f"{action} requires {field}")
        raise SystemExit(1)

    try:
        parsed = int(value) if integer else float(value)
    except (TypeError, ValueError):
        kind = "integer" if integer else "number"
        log_error(f"{action} {field} must be a {kind}")
        raise SystemExit(1)

    if parsed < 0:
        log_error(f"{action} {field} must be >= 0")
        raise SystemExit(1)


# =============================================================================
# Action handlers
#
# One unit per action: parse(value, index) -> args (raises on invalid), and
# run(args) executes the parsed step. Register the pair in ACTIONS below.
# =============================================================================
def parse_press(value, index):
    if value is None or str(value) == "":
        log_error(f"step {index} press requires a key")
        raise SystemExit(1)
    return {"key": str(value)}


def run_press(args):
    key_press(args["key"])


def parse_repeat(value, index):
    if not isinstance(value, dict):
        log_error("repeat requires key and times")
        raise SystemExit(1)
    if "key" not in value or value["key"] is None or str(value["key"]) == "":
        log_error("repeat requires key")
        raise SystemExit(1)
    if "times" not in value or value["times"] is None:
        log_error("repeat requires times")
        raise SystemExit(1)
    try:
        times = int(value["times"])
    except (TypeError, ValueError):
        log_error("repeat times must be an integer")
        raise SystemExit(1)
    if times < 0:
        log_error("repeat times must be >= 0")
        raise SystemExit(1)
    return {"key": str(value["key"]), "times": times}


def run_repeat(args):
    key_repeat(args["key"], args["times"])


def parse_wait(value, index):
    validate_number("wait", value, allow_empty=True)
    seconds = None if value is None or str(value) == "" else float(value)
    return {"seconds": seconds}


def run_wait(args):
    if args["seconds"] is None:
        wait_for_refresh()
    else:
        wait_for_refresh(args["seconds"])


def parse_countdown(value, index):
    validate_number("countdown", value, integer=True, allow_empty=True)
    seconds = None if value is None or str(value) == "" else int(value)
    return {"seconds": seconds}


def run_countdown(args):
    seconds = args["seconds"]
    wait_countdown(3 if seconds is None else seconds, "Waiting")


def parse_wait_on(value, index):
    template_expr = read_template_expr("wait_on", value)
    if "timeout" in value and value["timeout"] is not None:
        validate_number("wait_on", value["timeout"], field="timeout")
    if "on_miss" in value and (value["on_miss"] is None or str(value["on_miss"]) == ""):
        log_error("wait_on on_miss must be a key")
        raise SystemExit(1)
    timeout = float(value["timeout"]) if value.get("timeout") else None
    on_miss = str(value["on_miss"]) if value.get("on_miss") else None
    return {"template": template_expr, "timeout": timeout, "on_miss": on_miss}


def run_wait_on(args):
    template_expr = args["template"]
    timeout = args["timeout"]
    if timeout is None:
        timeout = VERIFY_TIMEOUT
    on_miss_key = args["on_miss"]

    label = format_template_expr(template_expr)
    start = time.time()

    while (time.time() - start) < timeout:
        frame = capture_frame(wait=0)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        debug = is_debug_enabled()
        r = eval_template_expr(gray, template_expr, debug=debug)
        if debug:
            log_debug(
                f"polling {label}: {format_template_details(r['details'])} matched={r['matched']}"
            )

        if r["matched"]:
            elapsed = time.time() - start
            log_info(f"{format_template_details(r['details'])}, took {elapsed:.1f}s")
            wait_poll_tick()
            return

        wait_poll_tick()
        if on_miss_key:
            key_press(on_miss_key)

    frame = capture_frame(wait=0)
    dump_diagnostics(frame, f"{template_tag(label)}_timeout")
    log_error(f"Did not detect {label} within {int(timeout)}s; stopping")
    raise SystemExit(1)


def parse_scroll_to(value, index):
    return {"template": read_template("scroll_to", value)}


def run_scroll_to(args):
    if scroll_to(args["template"]) is None:
        log_info("No matches found; stopping")
        sys.exit(0)


def parse_purge(value, index):
    return {
        "template": read_mapping_template("purge", value),
        "marker": read_marker("purge", value),
        "brand_new": read_brand_new("purge", value),
    }


def run_purge(args):
    template = args["template"]
    marker = args["marker"]
    brand_new_filter = args["brand_new"]
    deletions = 0
    iter_idx = 0
    log_info(
        f"purge template={template} marker={describe_marker(marker)} brand_new={describe_brand_new(brand_new_filter)}"
    )

    while True:
        result = scroll_right_to(template)
        if result is None:
            log_info(f"No more matches; done ({deletions} deletions)")
            return

        frame = result["frame"] if result["frame"] is not None else capture_frame()
        slices = slice_grid(frame)
        if dump_is_enabled():
            dump_save_cells(slices["cells"], f"iter{iter_idx}")

        frame_w = slices["frame"].shape[1]
        scan = _purge_candidate(
            slices["cells"],
            frame_w,
            template,
            marker,
            brand_new_filter,
            slices["focused"],
        )

        if scan["candidate"] is None:
            if is_edge_empty(
                cv2.cvtColor(slices["frame"], cv2.COLOR_BGR2GRAY), "right"
            ):
                log_info(f"Last page, no more candidates; done ({deletions} deletions)")
                return

            log_info("no candidate this view; right 4")
            key_repeat("right", 4)
            continue

        t = scan["candidate"]
        if scan["focused_is_candidate"]:
            log_info(f"focused candidate at c{t[0]}r{t[1]}")
        else:
            log_info(f"candidate at c{t[0]}r{t[1]}")
            move_cursor(slices["focused"], t)
        key_press("enter")
        wait_for_refresh()
        key_repeat("down", 4)
        key_press("enter")
        wait_for_refresh()
        key_press("down")
        key_press("enter")
        deletions += 1
        log_info(f"deleted ({deletions})")
        iter_idx += 1


def parse_snap(value, index):
    if value not in (None, ""):
        log_error("snap does not accept arguments")
        raise SystemExit(1)
    return {}


def run_snap(args):
    dump_ensure_dir()
    frame = capture_frame(wait=0)
    d = dump_get_dir()
    cv2.imwrite(str(d / "frame.png"), frame)
    g = get_grid_cells(frame)

    for col in range(4):
        for row in range(3):
            cell = g["cells"][col][row]
            cv2.imwrite(str(d / f"c{col}r{row}_slot.png"), cell["bgr"])
            cv2.imwrite(str(d / f"c{col}r{row}_brand_new.png"), cell["yellow_bgr"])

    log_info(f"wrote frame + 24 slot crops to {d}")


_last_detect_match_time = None
_detect_count = 0


def parse_detect(value, index):
    if not isinstance(value, dict) or not value:
        log_error("detect requires templates")
        raise SystemExit(1)
    if "templates" not in value:
        log_error("detect requires templates")
        raise SystemExit(1)
    unexpected = set(value) - {"count", "templates"}
    if unexpected:
        log_error("detect only accepts count and templates")
        raise SystemExit(1)
    count_limit = None
    if "count" in value:
        if isinstance(value["count"], bool):
            log_error("detect count must be an integer")
            raise SystemExit(1)
        try:
            count_limit = int(value["count"])
        except (TypeError, ValueError):
            log_error("detect count must be an integer")
            raise SystemExit(1)
        if count_limit <= 0:
            log_error("detect count must be > 0")
            raise SystemExit(1)
    templates = value["templates"]
    if not isinstance(templates, dict) or not templates:
        log_error("detect templates requires one or more template-to-key mappings")
        raise SystemExit(1)
    for template, key in templates.items():
        if template is None or str(template) == "" or key is None or str(key) == "":
            log_error("detect mappings must be template: key")
            raise SystemExit(1)
    screen_map = {str(k): str(v) for k, v in templates.items()}
    return {
        "screen_map": screen_map,
        "count_template": next(iter(screen_map)),
        "count_limit": count_limit,
    }


def run_detect(args):
    global _last_detect_match_time, _detect_count
    screen_map = args["screen_map"]
    count_template = args["count_template"]
    count_limit = args["count_limit"]

    try:
        frame = capture_frame(wait=POLL_INTERVAL)
    except Exception as e:
        log_error(f"{e} -- pausing 1s and retrying")
        time.sleep(1)
        return

    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

    matched = None
    match_details = None
    for n in screen_map:
        r = match_template(gray, n)
        if r["matched"]:
            matched = n
            match_details = [template_detail(n, r)]
            break

    if matched:
        now = time.time()
        if _last_detect_match_time is None:
            timing = "first match"
        else:
            timing = f"since last {now - _last_detect_match_time:.1f}s"
        _last_detect_match_time = now

        key = screen_map[matched]
        if matched == count_template:
            if count_limit is not None and _detect_count >= count_limit:
                log_info(f"total {count_limit} reached; stopping")
                raise SystemExit(0)

            _detect_count += 1
            log_info(f"****** {count_template}_count={_detect_count} ******")

        log_info(f"{format_template_details(match_details)}, {timing} -> press {key}")
        key_press(key)


# Action registry: name -> (parse, run). Add a new action with one entry here.
ACTIONS = {
    "press": (parse_press, run_press),
    "repeat": (parse_repeat, run_repeat),
    "wait": (parse_wait, run_wait),
    "countdown": (parse_countdown, run_countdown),
    "wait_on": (parse_wait_on, run_wait_on),
    "scroll_to": (parse_scroll_to, run_scroll_to),
    "purge": (parse_purge, run_purge),
    "snap": (parse_snap, run_snap),
    "detect": (parse_detect, run_detect),
}


def compile_step(step, index):
    if not isinstance(step, dict) or len(step) != 1:
        log_error(f"step {index} must be a single action mapping")
        raise SystemExit(1)

    name = list(step.keys())[0]
    if name not in ACTIONS:
        log_error(f"Unknown action: {name}")
        raise SystemExit(1)

    parse, _ = ACTIONS[name]
    return {"name": name, "args": parse(step[name], index)}


def validate_workflow(workflow):
    if not isinstance(workflow, dict):
        log_error("workflow must be a mapping")
        raise SystemExit(1)

    if (
        "steps" not in workflow
        or not isinstance(workflow["steps"], list)
        or not workflow["steps"]
    ):
        log_error("workflow requires non-empty steps")
        raise SystemExit(1)

    if "loop" in workflow and not isinstance(workflow["loop"], bool):
        validate_number("workflow", workflow["loop"], field="loop", integer=True)

    if "focus_mode" in workflow and str(workflow["focus_mode"]) not in (
        "exit",
        "pause",
    ):
        log_error("workflow focus_mode must be exit or pause")
        raise SystemExit(1)

    for field in ("await_focus", "report_cycle_time"):
        if field in workflow and not isinstance(workflow[field], bool):
            log_error(f"workflow {field} must be true or false")
            raise SystemExit(1)

    if "hold" in workflow:
        hold = workflow["hold"]
        if (
            not isinstance(hold, dict)
            or "key" not in hold
            or hold["key"] is None
            or str(hold["key"]) == ""
        ):
            log_error("workflow hold requires key")
            raise SystemExit(1)
        if "release_on_lose_focus" in hold and not isinstance(
            hold["release_on_lose_focus"], bool
        ):
            log_error("workflow hold release_on_lose_focus must be true or false")
            raise SystemExit(1)

    compiled = [
        compile_step(step, index)
        for index, step in enumerate(workflow["steps"], start=1)
    ]

    log_info("Validated workflow")
    return compiled


# =============================================================================
# Step runner
# =============================================================================
def run_step(compiled):
    name = compiled["name"]
    log_set_step(name)
    _, run = ACTIONS[name]
    run(compiled["args"])
    log_set_step(None)


# =============================================================================
# Workflow runner
# =============================================================================
def run_workflow(workflow, steps):
    loop_val = workflow.get("loop", False)

    if loop_val is True:
        max_cycles = -1
    elif loop_val is False:
        max_cycles = 1
    else:
        max_cycles = int(loop_val)

    if max_cycles == 0:
        max_cycles = 1

    focus_mode = str(workflow.get("focus_mode", "exit"))

    hold_keys = {}
    if "hold" in workflow:
        h = workflow["hold"]
        k = str(h["key"]).upper()

        if "release_on_lose_focus" in h:
            release = h["release_on_lose_focus"] is True
        else:
            release = True

        hold_keys[k] = {"held": False, "release_on_lose_focus": release}
        log_info(f"Hold: {k} (release_on_lose_focus={release})")

    if "report_cycle_time" in workflow:
        report_cycle_time = workflow["report_cycle_time"] is True
    else:
        report_cycle_time = False

    cycle = 0

    try:
        while True:
            cycle += 1
            if max_cycles > 0:
                log_info(f"cycle {cycle}/{max_cycles} starting")

            cycle_start = time.time()

            for step in steps:
                if not is_window_focused():
                    if focus_mode == "exit":
                        log_error("Lost focus, stopping")
                        sys.exit(1)

                    for k, h in hold_keys.items():
                        if h["held"] and h["release_on_lose_focus"]:
                            release_key(k)
                            h["held"] = False

                    while not is_window_focused():
                        wait_poll_tick()

                for k, h in hold_keys.items():
                    if not h["held"]:
                        hold_key(k)
                        h["held"] = True
                    elif not is_key_held(k):
                        log_debug(f"{k} dropped, re-pressing")
                        hold_key(k)

                run_step(step)

            if report_cycle_time:
                elapsed = time.time() - cycle_start
                if max_cycles > 0:
                    log_info(f"cycle {cycle}/{max_cycles} completed in {elapsed:.1f}s")
                else:
                    log_info(f"cycle {cycle} completed in {elapsed:.1f}s")

                log_info("----------------------------------------")

            if max_cycles > 0 and cycle >= max_cycles:
                break

    finally:
        for k, h in hold_keys.items():
            if h["held"]:
                release_key(k)


# =============================================================================
# Main
# =============================================================================
def main():
    parser = argparse.ArgumentParser(description="Forza Horizon 6 automation CLI")
    parser.add_argument("action", nargs="?", help="Workflow name or path to YAML file")
    parser.add_argument("-d", "--dump", action="store_true", help="Save debug frames")
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable debug logs"
    )
    args = parser.parse_args()

    if not args.action:
        print("Forza Horizon 6 automation CLI")
        print()
        print("Usage:")
        print("  python cli.py <name|path.yaml> [-d] [-v]")
        return

    action = args.action
    if action.endswith(".yaml") or action.endswith(".yml"):
        yaml_path = Path(action)
    else:
        yaml_path = _ROOT / "workflows" / f"{action}.yaml"

    if not yaml_path.exists():
        print(f"Workflow not found: {yaml_path}", file=sys.stderr)
        sys.exit(1)

    with open(yaml_path) as f:
        workflow = yaml.safe_load(f)

    dump_set_mode(args.dump)
    if args.dump:
        dump_ensure_dir()
        log_file = dump_get_dir() / "cli.log"
    else:
        log_file = None

    log_setup(verbose=args.verbose, log_file=log_file)
    compiled = validate_workflow(workflow)

    log_info("=== workflow starting ===")

    hwnd = get_game_window()
    if hwnd is None:
        log_error(f"Window '{WINDOW_TITLE}' not found")
        sys.exit(1)

    log_info(f"Found window: {WINDOW_TITLE}")

    wait_focus = workflow.get("await_focus", False)
    if wait_focus is True:
        log_info("Waiting for game window focus...")
        while not is_window_focused():
            wait_poll_tick()

        log_info("Game window focused")

    wait_countdown(3, "Starting")

    frame = capture_frame(wait=0)
    h, w = frame.shape[:2]
    log_info(f"Captured frame {w}x{h}")

    run_workflow(workflow, compiled)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log_info("interrupted")
        sys.exit(0)
