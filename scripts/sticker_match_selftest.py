"""离线自检：拿下载好的收藏图拼一张假面板，验证 --index 的图像匹配能不能认出目标格子。
不碰微信窗口，纯算法。"""
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
import sys

from PIL import Image

spec = importlib.util.spec_from_file_location("wx_sticker", os.path.join(HERE, "wx_sticker.py"))
ws = importlib.util.module_from_spec(spec)
sys.modules["wx_sticker"] = ws
spec.loader.exec_module(ws)

FAV = ws.FAV_DIR
picks = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 19, 21, 24, 29, 33, 34, 35]
CELL = 110
COLS, ROWS = 5, 4
PANEL_W = COLS * CELL + 40
PANEL_H = ROWS * CELL + 80

panel = Image.new("RGB", (PANEL_W, PANEL_H), (255, 255, 255))
for n, idx in enumerate(picks):
    p = ws.find_sticker_file(idx)
    if not p:
        print("missing", idx)
        continue
    im = Image.open(p).convert("RGBA")
    im.thumbnail((CELL - 20, CELL - 20))
    bg = Image.new("RGB", im.size, (255, 255, 255))
    bg.paste(im, (0, 0), im)
    x = 20 + (n % COLS) * CELL + (CELL - bg.size[0]) // 2
    y = 20 + (n // COLS) * CELL + (CELL - bg.size[1]) // 2
    panel.paste(bg, (x, y))

out = os.path.join(os.environ.get("TEMP", "."), "fake_panel.png")
panel.save(out)
print("fake panel:", out, panel.size)

geo = ws.grid_from_panel(panel)
print("grid cols=%s rows=%s" % (geo["cols"], geo["rows"]))

ok = 0
for n, idx in enumerate(picks):
    target = ws.content_sig(Image.open(ws.find_sticker_file(idx)))
    s, cx, cy, ri, ci = ws.match_sticker(panel, target)
    want_r, want_c = n // COLS, n % COLS
    hit = (ri == want_r and ci == want_c)
    ok += 1 if hit else 0
    print("#%-2d -> r%d c%d score %.3f %s" % (idx, ri, ci, s, "OK" if hit else "MISS (want r%d c%d)" % (want_r, want_c)))
print("matched %d/%d" % (ok, len(picks)))
