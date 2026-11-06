#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""wx_sticker.py v4 —— 先走缓存的「标准快路径」，不对才做「看一眼」的慢流程。

设计（2026-10-24 晚）
  * 屏幕/窗口布局固定时，坐标是稳定的：把「笑脸位置 + 面板尺寸 + 收藏 tab + 格子行列」
    缓存到 sticker_profile.json（key = 屏幕分辨率 + DPI 缩放 + 窗口宽高）。
  * 命中缓存 → 直接点（不截图、不聚类），2~3 秒发完；点完仍会回读一次聊天区做校验。
  * 没命中 / 校验失败 → 走慢流程：截图认图标行 → 点笑脸 → 认面板窗口 → 认 tab → 认格子，
    成功后把这次量到的几何写回缓存，下次就快了。
  * 窗口被缩放、最大化、拖动导致宽高变化 → 自动退回慢流程并更新缓存。

用法
  python wx_sticker.py                # 自动：快路径优先，失败退慢流程
  python wx_sticker.py --slow         # 强制走检测流程
  python wx_sticker.py --dry-run      # 只看不点
  python wx_sticker.py --row 1 --col 2 --seed 3
"""
import argparse
import ctypes
import json
import os
import random
import re
import subprocess
import time

import numpy as np
from PIL import Image, ImageDraw, ImageGrab

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

DEBUG_DIR = r"E:\DSH\GZJT GC"
PROFILE = r"C:\Users\LX\.dsh\weixin\wcdb\sticker_profile.json"
WX_SEND = r"C:\Users\LX\.dsh\weixin\wcdb\wx_send.ps1"
WX_ACT = r"C:\Users\LX\.dsh\weixin\wcdb\wx_activity.ps1"
PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP = 0x0200, 0x0201, 0x0202


class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


class BadWindowRect(RuntimeError):
    """窗口已经没了/被隐藏（表情面板是即开即弃的）。"""


def log(msg):
    print(msg, flush=True)


def set_dpi_aware():
    try:
        user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except Exception:
        pass


def screen_key():
    w = user32.GetSystemMetrics(0)
    h = user32.GetSystemMetrics(1)
    dpi = user32.GetDpiForSystem() if hasattr(user32, "GetDpiForSystem") else 96
    try:
        dpi = user32.GetDpiForSystem()
    except Exception:
        dpi = 96
    return "%dx%d@%d" % (w, h, dpi)


def load_profile():
    try:
        with open(PROFILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_profile(prof):
    try:
        with open(PROFILE, "w", encoding="utf-8") as f:
            json.dump(prof, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log("WARN: cannot save profile: %s" % e)


def resolve_hwnd():
    out = subprocess.run([PS, "-NoProfile", "-ExecutionPolicy", "Bypass",
                          "-File", WX_SEND, "-ResolveOnly"],
                         capture_output=True, text=True, encoding="gbk", errors="replace")
    text = (out.stdout or "") + (out.stderr or "")
    m = re.search(r"hwnd=(\d+)", text)
    if not m:
        raise SystemExit("resolve failed: " + text.strip()[:300])
    pid = re.search(r"pid=(\d+)", text)
    return int(m.group(1)), (int(pid.group(1)) if pid else 0)


def enum_windows(pid):
    out = []
    EP = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def cb(h, lp):
        p = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(h, ctypes.byref(p))
        if p.value == pid and user32.IsWindowVisible(h):
            r = RECT()
            user32.GetWindowRect(h, ctypes.byref(r))
            cls = ctypes.create_unicode_buffer(128)
            user32.GetClassNameW(h, cls, 128)
            out.append(dict(hwnd=int(h), cls=cls.value, left=r.left, top=r.top,
                            w=r.right - r.left, h=r.bottom - r.top))
        return True

    user32.EnumWindows(EP(cb), 0)
    return out


def pick_main(hwnd, pid):
    best, best_area = None, 0
    for w in enum_windows(pid):
        if "QWindowIcon" in w["cls"] and w["w"] * w["h"] > best_area:
            best, best_area = w["hwnd"], w["w"] * w["h"]
    return best or hwnd


def find_panel(pid, main_hwnd):
    cands = [w for w in enum_windows(pid)
             if "ToolSaveBits" in w["cls"] and w["hwnd"] != main_hwnd
             and w["w"] * w["h"] > 400 * 300]
    return max(cands, key=lambda w: w["w"] * w["h"]) if cands else None


def capture_window(hwnd):
    rect = RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if w <= 0 or h <= 0:
        # 面板是即开即弃的：切 tab、滚轮都可能把旧 hwnd 变没，调用方必须重找。
        raise BadWindowRect("window %s has no size (%dx%d)" % (hwnd, w, h))
    hdc_win = user32.GetWindowDC(hwnd)
    hdc_mem = gdi32.CreateCompatibleDC(hdc_win)
    hbmp = gdi32.CreateCompatibleBitmap(hdc_win, w, h)
    gdi32.SelectObject(hdc_mem, hbmp)
    user32.PrintWindow(hwnd, hdc_mem, 2)

    class BIH(ctypes.Structure):
        _fields_ = [("biSize", ctypes.c_uint32), ("biWidth", ctypes.c_long),
                    ("biHeight", ctypes.c_long), ("biPlanes", ctypes.c_ushort),
                    ("biBitCount", ctypes.c_ushort), ("biCompression", ctypes.c_uint32),
                    ("biSizeImage", ctypes.c_uint32), ("biXPelsPerMeter", ctypes.c_long),
                    ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", ctypes.c_uint32),
                    ("biClrImportant", ctypes.c_uint32)]

    bmi = BIH()
    bmi.biSize = ctypes.sizeof(BIH)
    bmi.biWidth = w
    bmi.biHeight = -h
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(hdc_mem, hbmp, 0, h, buf, ctypes.byref(bmi), 0)
    gdi32.DeleteObject(hbmp)
    gdi32.DeleteDC(hdc_mem)
    user32.ReleaseDC(hwnd, hdc_win)
    arr = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 4)[:, :, :3][:, :, ::-1]
    return Image.fromarray(arr.copy()), (rect.left, rect.top, w, h)


def gray(img):
    return np.asarray(img.convert("L"), dtype=np.int16)


def cluster_1d(mask, min_gap, min_size):
    idx = np.flatnonzero(mask)
    if idx.size == 0:
        return []
    groups, start, prev = [], idx[0], idx[0]
    for i in idx[1:]:
        if i - prev > min_gap:
            groups.append((start, prev))
            start = i
        prev = i
    groups.append((start, prev))
    return [((a + b) // 2, b - a + 1) for a, b in groups if b - a + 1 >= min_size]


def find_icon_row(g):
    h, w = g.shape
    x0, x1 = int(w * 0.22), int(w * 0.80)
    dark = (g[:, x0:x1] < 120).sum(axis=1)
    y = h - 16
    while y > int(h * 0.55) and dark[y] < 5:
        y -= 1
    if y <= int(h * 0.55):
        return None
    y1, gap, y0 = y, 0, y
    yy = y - 1
    while yy > int(h * 0.55):
        if dark[yy] >= 2:
            y0, gap = yy, 0
        else:
            gap += 1
            if gap > 4:
                break
        yy -= 1
    return (y0, min(h - 1, y1 + 1))


def find_smiley(img):
    g = gray(img)
    h, w = g.shape
    row = find_icon_row(g)
    if not row:
        return None
    y0, y1 = row
    band = np.flatnonzero((g[y0:y1, :] < 130).sum(axis=0) >= 3)
    clusters = cluster_1d(np.isin(np.arange(w), band), 24, 8)
    clusters = [(c, s) for c, s in clusters if int(w * 0.20) < c < int(w * 0.85)]
    run, best = [], []
    for c in clusters:
        if run and 35 <= c[0] - run[-1][0] <= 75:
            run.append(c)
        else:
            if len(run) > len(best):
                best = run
            run = [c]
    if len(run) > len(best):
        best = run
    if len(best) < 4:
        return None
    return int(best[0][0]), int((y0 + y1) // 2)


def wait_panel(pid, main_hwnd, timeout=1.2):
    t0 = time.time()
    while time.time() - t0 < timeout:
        p = find_panel(pid, main_hwnd)
        if p:
            return p
        time.sleep(0.05)
    return None


def signature(img, n=24):
    small = img.convert("L").resize((n, n))
    return np.asarray(small, dtype=np.uint8).flatten().tolist()


def wait_chat_change(hwnd, before, timeout=1.5):
    a0 = gray(before)
    w = a0.shape[1]
    t0 = time.time()
    while time.time() - t0 < timeout:
        now, _ = capture_window(hwnd)
        a = gray(now)
        if a.shape == a0.shape:
            changed = int((np.abs(a[:, int(w * 0.45):] - a0[:, int(w * 0.45):]) > 25).sum())
            if changed > 800:
                return now, changed
        time.sleep(0.12)
    return None, 0

def focus(hwnd):
    fg = user32.GetForegroundWindow()
    tid_fg = user32.GetWindowThreadProcessId(fg, None)
    tid_self = kernel32.GetCurrentThreadId()
    if tid_fg and tid_fg != tid_self:
        user32.AttachThreadInput(tid_fg, tid_self, True)
    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)
    if tid_fg and tid_fg != tid_self:
        user32.AttachThreadInput(tid_fg, tid_self, False)
    time.sleep(0.3)
    return user32.GetForegroundWindow() == hwnd


def ensure_foreground(hwnd, rect=None, tries=2):
    """把窗口真正激活。
    坑（2026-10-30）：虚拟桌面里 SetForegroundWindow 常常失败，此时第一次点击只会
    激活窗口、不会传给控件 —— 点笑脸就打不开面板。所以失败时补一次标题栏点击。"""
    if focus(hwnd):
        return True
    r = rect or RECT()
    if rect is None:
        user32.GetWindowRect(hwnd, ctypes.byref(r))
    for _ in range(tries):
        real_click(r.left + (r.right - r.left) // 2, r.top + 16, 0.45)   # 标题栏空白处
        if user32.GetForegroundWindow() == hwnd:
            time.sleep(0.2)
            return True
        focus(hwnd)
    return user32.GetForegroundWindow() == hwnd


def real_click(x, y, pause=0.4):
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.06)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.04)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(pause)


def grab(bbox=None):
    return ImageGrab.grab(bbox=bbox)


def save_debug(img, name, pts=()):
    os.makedirs(DEBUG_DIR, exist_ok=True)
    path = os.path.join(DEBUG_DIR, "stk-%s-%s.png" % (name, time.strftime("%H%M%S")))
    im = img.copy()
    d = ImageDraw.Draw(im)
    for (x, y), color in pts:
        d.ellipse([x - 8, y - 8, x + 8, y + 8], outline=color, width=2)
    im.save(path)
    log("debug: " + path)
    return path


def panel_picture(panel):
    """PrintWindow 抓面板本身。ImageGrab 对这块分层窗口只能拿到下面的聊天，
    所以这里必须走 PrintWindow（2026-10-30 实测）。"""
    img, _ = capture_window(panel["hwnd"])
    return img


FAV_DIR = r"C:\Users\LX\.dsh\weixin\wcdb\sticker_lab\fav"


def content_sig(img, n=24):
    """裁到内容外框（去掉白底/透明边），再归一化成 n*n 灰度，用作模板签名。"""
    rgb = img.convert("RGB")
    a = np.asarray(rgb).astype(np.int16)
    if "A" in img.getbands():
        alpha = np.asarray(img.getchannel("A"))
        mask = alpha > 24
    else:
        mask = (255 - a.min(axis=2)) > 20          # 明显不是纯白的像素
    ys, xs = np.nonzero(mask)
    if ys.size < 20:
        return None
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    if (y1 - y0) < 6 or (x1 - x0) < 6:
        return None
    crop = img.crop((int(x0), int(y0), int(x1), int(y1))).convert("L").resize((n, n))
    v = np.asarray(crop, dtype=np.float32).flatten()
    v = v - v.mean()
    s = float(np.linalg.norm(v))
    return v / s if s > 1e-6 else None


def pearson(a, b):
    if a is None or b is None:
        return -1.0
    return float(np.dot(a, b))


def find_sticker_file(index):
    """收藏序号 → 下载下来的 PNG。fav\\NN_<md5>.png"""
    if not os.path.isdir(FAV_DIR):
        return None
    pat = re.compile(r"^(\d+)_")
    for name in sorted(os.listdir(FAV_DIR)):
        m = pat.match(name)
        if m and int(m.group(1)) == int(index) and name.lower().endswith((".png", ".jpg", ".gif", ".jpeg")):
            return os.path.join(FAV_DIR, name)
    return None


def card_box(img):
    """PrintWindow 截图外面是黑的（透明），卡片是亮的：取非黑外框。"""
    a = np.asarray(img.convert("RGB")).astype(np.int16)
    mask = a.sum(axis=2) > 90
    ys, xs = np.nonzero(mask)
    if ys.size == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def grid_from_panel(img):
    """在干净的面板截图里量出格子行列（彩色像素投影聚类）。
    返回 dict(cols=[x...], rows=[y...], box, tab=[(x,y)...], sample)。"""
    a = np.asarray(img.convert("RGB"))
    box = card_box(img)
    if box is None:
        return None
    x0, y0, x1, y1 = box
    card = img.crop(box)
    ch, cw = card.size[1], card.size[0]
    hsv = np.asarray(card.convert("HSV")).astype(np.int16)
    sat, val = hsv[:, :, 1], hsv[:, :, 2]
    body_h = int(ch * 0.86)                      # 下面 14% 是页签行
    ink = ((sat > 55) & (val > 45))[:body_h, :]
    cols = [int(c[0]) for c in cluster_1d(ink.sum(axis=0) > 3, 10, 14)]
    rows = [int(r[0]) for r in cluster_1d(ink.sum(axis=1) > 3, 10, 14)]
    tabs = []
    for ty in range(int(ch * 0.86), ch - 6, 2):
        band = ((val[ty:ty + 9, :] < 200)).sum(axis=0) >= 2
        cl = [c for c in cluster_1d(band, 12, 6) if 40 <= c[0] <= cw - 40 and c[1] <= 40]
        if 2 <= len(cl) <= 4 and all(30 <= cl[i + 1][0] - cl[i][0] <= 90 for i in range(len(cl) - 1)):
            tabs = [(int(c[0]), int(ty + 6)) for c in cl]
            break
    return dict(box=(x0, y0, x1, y1), cols=cols, rows=rows, tabs=tabs, sample=img)


def cell_boxes(geo):
    """把行列中心改成一个个格子外框（相对面板窗口左上角）。
    最后一排常被页签行压住一半，中心点会点到 tab 上，所以裁掉它。"""
    ox, oy = geo["box"][0], geo["box"][1]
    cols, rows = geo["cols"], geo["rows"]
    if not cols or not rows:
        return []
    body_bottom = oy + int((geo["box"][3] - oy) * 0.87)
    px = int(np.median(np.diff(cols))) if len(cols) > 1 else 110
    py = int(np.median(np.diff(rows))) if len(rows) > 1 else 110
    hx, hy = int(px * 0.46), int(py * 0.46)
    out = []
    for ri, cy in enumerate(rows):
        if oy + cy > body_bottom:
            continue
        for ci, cx in enumerate(cols):
            out.append((ri, ci, ox + cx - hx, oy + cy - hy, ox + cx + hx, oy + cy + hy, ox + cx, oy + cy))
    return out


def match_sticker(img, target_sig, geo=None):
    """在面板截图里找 target 表情：逐格比内容签名，返回 (score, cx, cy, ri, ci)。"""
    geo = geo or grid_from_panel(img)
    if geo is None:
        return (-1.0, 0, 0, -1, -1)
    best = (-1.0, 0, 0, -1, -1)
    for ri, ci, ax, ay, bx, by, cx, cy in cell_boxes(geo):
        cell = img.crop((ax, ay, bx, by))
        s = pearson(content_sig(cell), target_sig)
        if s > best[0]:
            best = (s, cx, cy, ri, ci)
    return best


def scroll_panel(panel, up=False, turns=3):
    cx = panel["left"] + panel["w"] // 2
    cy = panel["top"] + int(panel["h"] * 0.45)
    user32.SetCursorPos(int(cx), int(cy))
    time.sleep(0.1)
    delta = 120 if up else -120
    for _ in range(turns):
        user32.mouse_event(0x0800, 0, 0, delta, 0)   # MOUSEEVENTF_WHEEL
        time.sleep(0.12)
    time.sleep(0.5)


def send_by_index(hwnd, pid, open_panel, index, verify=True, pages=4, dry_run=False):
    """按收藏序号发：开面板 → 切收藏 tab → 逐页按图像匹配找格子 → 点它。
    面板是即开即弃的（切 tab / 滚轮都可能换窗口），所以每次截图前都用 find_panel 重拿。
    返回 dict(ok, score, ri, ci, page, file)。"""
    path = find_sticker_file(index)
    if not path:
        return dict(ok=False, error="no downloaded png for index %s" % index, file=None)
    target = content_sig(Image.open(path))
    if target is None:
        return dict(ok=False, error="target image empty: %s" % path, file=path)

    def shot():
        """返回 (panel, image)；面板没了就重开，最多三次。"""
        for _ in range(3):
            p = find_panel(pid, hwnd) or open_panel()
            if not p:
                return None, None
            try:
                return p, panel_picture(p)
            except BadWindowRect:
                time.sleep(0.25)
        return None, None

    panel, img = shot()
    if panel is None:
        return dict(ok=False, error="panel did not open", file=path)
    geo = grid_from_panel(img)
    if not geo or len(geo["cols"]) < 3 or len(geo["rows"]) < 2:
        save_debug(img, "idx-nogrid")
        return dict(ok=False, error="grid not detected", file=path)
    # 切到收藏 tab（最后一个页签）
    if geo["tabs"]:
        tx, ty = geo["tabs"][-1]
        ox, oy = geo["box"][0], geo["box"][1]
        real_click(panel["left"] + ox + tx, panel["top"] + oy + ty, 0.7)
        panel, img = shot()
        if panel is None:
            return dict(ok=False, error="panel closed when switching to favourites", file=path)
        geo = grid_from_panel(img) or geo

    best = (-1.0, 0, 0, -1, -1, 0)
    for page in range(pages):
        panel, img = shot()
        if panel is None:
            break
        g = grid_from_panel(img)
        s, cx, cy, ri, ci = match_sticker(img, target, g)
        log("page %d: best score=%.3f cell r%d c%d (target #%s)" % (page, s, ri, ci, index))
        if s > best[0]:
            best = (s, cx, cy, ri, ci, page)
        if s >= 0.80 or dry_run:
            break
        scroll_panel(panel)
    s, cx, cy, ri, ci, page = best
    panel, img = shot()
    if panel is not None:
        save_debug(img, "idx-match", [((cx, cy), "red")] if cx else [])
    if dry_run:
        return dict(ok=True, dry_run=True, score=s, ri=ri, ci=ci, page=page, file=path)
    if s < 0.60:
        return dict(ok=False, error="no confident match (best %.3f)" % s, score=s, file=path)
    if panel is None:
        return dict(ok=False, error="panel died before the click", score=s, file=path)
    before, _ = capture_window(hwnd)
    real_click(panel["left"] + cx, panel["top"] + cy, 0.5)
    if verify:
        after, changed = wait_chat_change(hwnd, before)
        log("chat-area changed pixels=%d" % changed)
        if after is None:
            return dict(ok=False, error="clicked but chat did not change", score=s, file=path)
        save_debug(after, "idx-sent")
    return dict(ok=True, score=s, ri=ri, ci=ci, page=page, file=path)


def card_bbox(pg):
    """面板窗口截图里含阴影边距；从中心泛洪出白色卡片区域，返回 (x0,y0,x1,y1)。"""
    h, w = pg.shape
    white = pg >= 244
    cx, cy = w // 2, h // 2
    if not white[cy, cx]:
        return 0, 0, w, h
    seen = np.zeros((h, w), dtype=bool)
    stack = [(cy, cx)]
    seen[cy, cx] = True
    while stack:
        y, x = stack.pop()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and white[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                stack.append((ny, nx))
    ys, xs = np.nonzero(seen)
    if ys.size == 0:
        return 0, 0, w, h
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def detect_panel_geometry(panel):
    """慢流程：从面板截图里量出 tab 行和格子行列（相对卡片左上角 = 点击基准）。"""
    pimg = panel_picture(panel)
    ph, pw = panel["h"], panel["w"]
    pg = gray(pimg)
    m = int(round(pw * 0.0435))     # 面板窗口左右各有约 4.3% 的阴影边距
    x0, y0, x1, y1 = m, m, pw - m, ph - m
    card_w, card_h = x1 - x0, y1 - y0
    log("slow: card=(%d,%d)-(%d,%d) %dx%d" % (x0, y0, x1, y1, card_w, card_h))
    card = pg[y0:y1, x0:x1]

    tab_top, tabs = card_h - 40, []
    for ty in range(int(card_h * 0.78), card_h - 8, 3):
        row = cluster_1d((card[ty:ty + 9, :] < 150).sum(axis=0) >= 2, 18, 5)
        if 3 <= len(row) <= 4 and all(36 <= row[i + 1][0] - row[i][0] <= 64
                                      for i in range(len(row) - 1)):
            tab_top, tabs = ty, row
    heart = [int(tabs[-1][0]), int(tab_top + 10)] if tabs else None
    body_top, body_bottom = int(card_h * 0.12), tab_top - 4
    body = card[body_top:body_bottom, 6:card_w - 6]
    cols = [int(6 + c[0]) for c in cluster_1d((body < 205).sum(axis=0) >= 4, 10, 16)]
    rows = [int(body_top + r[0]) for r in cluster_1d((body < 205).sum(axis=1) >= 4, 10, 16)]
    log("slow: tabs=%s heart=%s" % (tabs, heart))
    return dict(w=pw, h=ph, ox=x0, oy=y0, heart=heart, cols=cols, rows=rows, sample=pimg)


def send_with_geometry(hwnd, panel, geo, ri, ci, verify=True, skip_heart=False):
    """用给定几何点收藏 tab 和格子；返回聊天区是否变化。"""
    ox, oy = geo.get("ox", 0), geo.get("oy", 0)
    if geo.get("heart") and not skip_heart:
        real_click(panel["left"] + ox + geo["heart"][0],
                   panel["top"] + oy + geo["heart"][1], 0.55)
    before, _ = capture_window(hwnd)
    cx = panel["left"] + ox + geo["cols"][ci]
    cy = panel["top"] + oy + geo["rows"][ri]
    real_click(cx, cy, 0.5)
    if not verify:
        return True
    after, changed = wait_chat_change(hwnd, before)
    log("chat-area changed pixels=%d" % changed)
    if after is not None:
        save_debug(after, "sent")
        return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--slow", action="store_true", help="跳过缓存，强制检测")
    ap.add_argument("--row", type=int)
    ap.add_argument("--col", type=int)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--index", type=int, help="按收藏序号发（图像匹配定位，不依赖行列映射）")
    ap.add_argument("--pages", type=int, default=4, help="--index 时最多翻几页找")
    args = ap.parse_args()

    set_dpi_aware()
    t0 = time.time()
    skey = screen_key()
    prof_all = load_profile()
    # 先试缓存里的 hwnd（省掉一次 PowerShell 解析，约 1 秒）
    hwnd, pid = 0, 0
    cached = prof_all.get("_hwnd") or {}
    if cached.get("hwnd") and user32.IsWindow(ctypes.c_void_p(cached["hwnd"])):
        hwnd, pid = int(cached["hwnd"]), int(cached.get("pid") or 0)
        log("hwnd from cache: %d" % hwnd)
    if not hwnd or not pid:
        hwnd, pid = resolve_hwnd()
        hwnd = pick_main(hwnd, pid)
    prof_all["_hwnd"] = dict(hwnd=int(hwnd), pid=int(pid))
    save_profile(prof_all)
    r0 = RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r0))
    if (r0.right - r0.left) < 400 or (r0.bottom - r0.top) < 300:
        log("window minimized - restoring")
        user32.ShowWindow(hwnd, 9)
        time.sleep(0.9)
    r0 = RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r0))
    W, H = r0.right - r0.left, r0.bottom - r0.top
    key = "%s|%dx%d" % (skey, W, H)
    log("hwnd=%d pid=%d window=%dx%d screen=%s key=%s" % (hwnd, pid, W, H, skey, key))

    prof = prof_all.get(key)
    rnd = random.Random(args.seed if args.seed is not None else time.time())

    # ---------- 按收藏序号发（图像匹配，不依赖行列映射） ----------
    if args.index is not None:
        base, _ = capture_window(hwnd)
        smiley = find_smiley(base) or (prof or {}).get("smiley")
        if not smiley:
            save_debug(base, "idx-nosmiley")
            raise SystemExit("smiley not found - abort")
        r1 = RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(r1))

        def open_panel():
            """必要时点笑脸开面板；返回 panel dict 或 None。"""
            p = find_panel(pid, hwnd)
            if p:
                return p
            ensure_foreground(hwnd, r1)
            real_click(r1.left + smiley[0], r1.top + smiley[1], 0.8)
            return wait_panel(pid, hwnd, 1.5)

        log("index mode: target=#%d" % args.index)
        res = send_by_index(hwnd, pid, open_panel, args.index, pages=args.pages,
                            dry_run=args.dry_run)
        log("index result: " + json.dumps(res, ensure_ascii=False))
        if res.get("ok") and not res.get("dry_run"):
            log("STICKER SENT ok by index #%d (page %d, score %.2f) in %.1fs"
                % (args.index, res.get("page", 0), res.get("score", 0), time.time() - t0))
            log_activity(res.get("ri", -1), res.get("ci", -1), "index")
            return
        if res.get("ok") and res.get("dry_run"):
            log("dry-run: matched index #%d at page %s" % (args.index, res.get("page")))
            return
        raise SystemExit("index send failed: %s" % res.get("error"))

    # ---------- 快路径 ----------
    if prof and not args.slow and not args.dry_run:
        log("fast path (cached geometry %.0fs ago)" % (time.time() - prof.get("ts", 0)))
        focus(hwnd)
        if not find_panel(pid, hwnd):
            real_click(r0.left + prof["smiley"][0], r0.top + prof["smiley"][1], 0.15)
        panel = wait_panel(pid, hwnd, 1.0)
        if panel and panel["w"] == prof["panel"]["w"] and panel["h"] == prof["panel"]["h"]:
            geo = prof["panel"]
            skip_heart = False
            if prof.get("sig"):
                cur = signature(panel_picture(panel))
                same = sum(1 for x, y in zip(cur, prof["sig"]) if abs(int(x) - int(y)) > 6)
                skip_heart = same < 40        # 面板看起来还是上次那个 tab，就不用再点收藏
                log("fast: panel signature diff=%d skip_heart=%s" % (same, skip_heart))
            ri = rnd.randrange(len(geo["rows"])) if args.row is None else args.row
            ci = rnd.randrange(len(geo["cols"])) if args.col is None else args.col
            ri = min(ri, len(geo["rows"]) - 1)
            ci = min(ci, len(geo["cols"]) - 1)
            log("fast: cell r%d c%d (cols=%d rows=%d)" % (ri, ci, len(geo["cols"]), len(geo["rows"])))
            if send_with_geometry(hwnd, panel, geo, ri, ci, skip_heart=skip_heart):
                prof["ts"] = time.time()
                prof["sig"] = signature(panel_picture(panel)) if panel else prof.get("sig")
                prof_all[key] = prof
                save_profile(prof_all)
                log("STICKER SENT ok via fast path in %.1fs" % (time.time() - t0))
                log_activity(ri, ci, "fast")
                return
            log("fast path verify failed -> falling back to detection")
        else:
            log("fast path: panel mismatch -> falling back")


    # ---------- 慢路径 ----------
    base, (L, T, W2, H2) = capture_window(hwnd)
    smiley = find_smiley(base)
    if not smiley:
        save_debug(base, "nosmiley")
        raise SystemExit("smiley not found - abort")
    log("slow: smiley at client(%d,%d)" % smiley)
    if args.dry_run:
        save_debug(base, "smiley", [(smiley, "red")])
        log("dry-run: stop (%.1fs)" % (time.time() - t0))
        return

    focus(hwnd)
    panel = find_panel(pid, hwnd)          # 可能已经不巧开着，那就直接用
    if not panel:
        real_click(L + smiley[0], T + smiley[1], 0.2)
        panel = wait_panel(pid, hwnd, 1.2)
    if not panel:
        save_debug(grab(), "nopanel")
        raise SystemExit("panel not found - abort")
    log("slow: panel %dx%d" % (panel["w"], panel["h"]))

    geo = detect_panel_geometry(panel)
    log("slow: heart=%s cols=%d rows=%d" % (geo.get("heart"), len(geo["cols"]), len(geo["rows"])))
    if len(geo["cols"]) < 3 or len(geo["rows"]) < 2:
        save_debug(geo["sample"], "nogrid")
        raise SystemExit("grid not detected - abort")

    ri = rnd.randrange(len(geo["rows"])) if args.row is None else min(args.row, len(geo["rows"]) - 1)
    ci = rnd.randrange(len(geo["cols"])) if args.col is None else min(args.col, len(geo["cols"]) - 1)
    ok = send_with_geometry(hwnd, panel, geo, ri, ci)
    log("slow: sent=%s (%.1fs)" % (ok, time.time() - t0))

    prof_all[key] = dict(ts=time.time(), hwnd=int(hwnd), pid=int(pid),
                         sig=signature(panel_picture(panel)),
                         smiley=[int(smiley[0]), int(smiley[1])],
                         panel=dict(w=int(geo["w"]), h=int(geo["h"]),
                                    ox=int(geo["ox"]), oy=int(geo["oy"]),
                                    heart=geo["heart"],
                                    cols=[int(c) for c in geo["cols"]],
                                    rows=[int(r) for r in geo["rows"]]))
    save_profile(prof_all)
    log("profile saved for key=%s" % key)
    if ok:
        log("STICKER SENT ok via detection")
        log_activity(ri, ci, "detect")
    else:
        log("WARN: chat unchanged - check manually")


def log_activity(ri, ci, mode):
    subprocess.run([PS, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", WX_ACT,
                    "-Add", "-Kind", "sticker", "-Actor", "desktop-bridge",
                    "-Text", "wx_sticker.py %s r%d c%d" % (mode, ri, ci)],
                   capture_output=True)


if __name__ == "__main__":
    main()








