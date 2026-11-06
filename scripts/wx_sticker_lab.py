#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""wx_sticker_lab.py —— 给表情收藏建索引（不发送）。

  python wx_sticker_lab.py --harvest            # 量当前页 + 逐格截图存 PNG
  python wx_sticker_lab.py --harvest --page 1   # 先翻一页再量（翻页靠滚轮）

产出（默认 C:\\Users\\LX\\.dsh\\weixin\\wcdb\\sticker_lab\\）：
  page{n}.png          整块面板（黑白卡片的原样，给我自己看布局）
  page{n}_r{r}c{c}.png 单格表情（四周留一点边，够认）
  page{n}.json         {cols,rows,cell_w,cell_h,items:[{r,c,x,y}]}  坐标是窗口客户区内的绝对点

只截图，不点格子；量完按 Esc 关面板。
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, r"C:\Users\LX\.dsh\weixin\wcdb")

import numpy as np
from PIL import Image

import wx_sticker as W

OUT = r"C:\Users\LX\.dsh\weixin\wcdb\sticker_lab"


def open_panel(hwnd, pid):
    W.focus(hwnd)
    panel = W.find_panel(pid, hwnd)
    if panel:
        W.log("lab: panel already open")
        return panel
    base, (L, T, WW, HH) = W.capture_window(hwnd)
    smiley = W.find_smiley(base)
    if not smiley:
        raise SystemExit("smiley not found")
    W.real_click(L + smiley[0], T + smiley[1], 0.35)
    panel = W.wait_panel(pid, hwnd, 1.5)
    if not panel:
        raise SystemExit("panel not found")
    return panel


def harvest(hwnd, pid, page):
    panel = open_panel(hwnd, pid)
    W.log("lab: panel %dx%d at %d,%d" % (panel["w"], panel["h"], panel["left"], panel["top"]))
    geo = W.detect_panel_geometry(panel)
    cols, rows = geo["cols"], geo["rows"]
    W.log("lab: cols=%s rows=%s" % (cols, rows))
    if len(cols) < 3 or len(rows) < 2:
        W.save_debug(geo["sample"], "lab-nogrid")
        raise SystemExit("grid not detected")

    # 点一次收藏 tab，确保看到的是收藏页
    ox, oy = geo["ox"], geo["oy"]
    if geo.get("heart"):
        W.real_click(panel["left"] + ox + geo["heart"][0], panel["top"] + oy + geo["heart"][1], 0.6)

    pic = W.panel_picture(panel)          # 面板窗口截图（含阴影边距）
    os.makedirs(OUT, exist_ok=True)
    base = os.path.join(OUT, "page%d" % page)
    pic.save(base + ".png")

    # 格子中心（面板窗口截图像素）
    xs = [ox + c for c in cols]
    ys = [oy + r for r in rows]
    step_x = int(round((xs[-1] - xs[0]) / max(1, len(xs) - 1))) if len(xs) > 1 else 100
    step_y = int(round((ys[-1] - ys[0]) / max(1, len(ys) - 1))) if len(ys) > 1 else 100
    half_x, half_y = max(28, step_x // 2), max(28, step_y // 2)

    items = []
    for ri, cy in enumerate(ys):
        for ci, cx in enumerate(xs):
            box = (max(0, cx - half_x), max(0, cy - half_y),
                   min(pic.width, cx + half_x), min(pic.height, cy + half_y))
            crop = pic.crop(box)
            # 放大 2 倍便于认
            crop = crop.resize((crop.width * 2, crop.height * 2), Image.LANCZOS)
            p = "%s_r%dc%d.png" % (base, ri, ci)
            crop.save(p)
            items.append(dict(r=ri, c=ci,
                              x=panel["left"] + cx, y=panel["top"] + cy,
                              file=os.path.basename(p)))
    meta = dict(page=page, cols=len(xs), rows=len(ys), step=[step_x, step_y],
                panel=[panel["left"], panel["top"], panel["w"], panel["h"]],
                origin=[panel["left"] + ox, panel["top"] + oy],
                items=items)
    with open(base + ".json", "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    W.log("lab: wrote %d cells for page %d -> %s" % (len(items), page, OUT))
    return meta


def close_panel(hwnd):
    W.focus(hwnd)
    W.user32.keybd_event(0x1B, 0, 0, 0)
    W.user32.keybd_event(0x1B, 0, 2, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--harvest", action="store_true")
    ap.add_argument("--page", type=int, default=0)
    ap.add_argument("--keep-open", action="store_true")
    a = ap.parse_args()
    W.set_dpi_aware()
    hwnd, pid = W.resolve_hwnd()
    hwnd = W.pick_main(hwnd, pid)
    W.log("lab: hwnd=%d pid=%d" % (hwnd, pid))
    if a.harvest:
        meta = harvest(hwnd, pid, a.page)
        if not a.keep_open:
            close_panel(hwnd)
        print(json.dumps({k: meta[k] for k in ("page", "cols", "rows")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
