#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""wx_sticker_catalog.py —— 从微信 CDN 把「收藏表情」全下回来，做成可检索的图库。

  python wx_sticker_catalog.py --fetch     # 下载全部收藏表情 -> sticker_lab/fav/
  python wx_sticker_catalog.py --sheet     # 拼带编号的大图方便人肉/模型认图

数据来源：
  C:\\Users\\LX\\.dsh\\weixin\\wcdb\\decrypted\\emoticon\\emoticon.db
    kFavEmoticonOrderTable   收藏顺序（第 1 条 jsb_emoticon_md5、第 2 条 dice_emoticon_md5 是石头剪刀布/骰子，
                             面板里也在最前面）
    kNonStoreEmoticonTable   每个 md5 的 cdn_url（可直接 GET，回 PNG）+ aes_key

产出：
  sticker_lab/fav/NN_<md5>.png        单张（NN 是收藏顺序，从 0 开始）
  sticker_lab/fav/index.json          [{i, md5, file, bytes}]
  sticker_lab/sheet1.png / sheet2.png 带序号的拼图
"""
import argparse
import json
import os
import sqlite3
import urllib.request

DB = r"C:\Users\LX\.dsh\weixin\wcdb\decrypted\emoticon\emoticon.db"
OUT = r"C:\Users\LX\.dsh\weixin\wcdb\sticker_lab\fav"
SHEET_DIR = r"C:\Users\LX\.dsh\weixin\wcdb\sticker_lab"


def fav_order():
    con = sqlite3.connect("file:%s?mode=ro" % DB.replace("\\", "/"), uri=True)
    order = [r[0] for r in con.execute("select md5 from kFavEmoticonOrderTable")]
    meta = {}
    for md5, cdn, aes, typ in con.execute(
            "select md5, cdn_url, aes_key, type from kNonStoreEmoticonTable"):
        meta[md5] = dict(cdn=(cdn or "").replace("&amp;", "&"), aes=aes, type=typ)
    con.close()
    return order, meta


def fetch():
    order, meta = fav_order()
    os.makedirs(OUT, exist_ok=True)
    items = []
    for i, md5 in enumerate(order):
        if md5 not in meta:            # jsb/dice 这类内置的没有 cdn
            items.append(dict(i=i, md5=md5, file=None, bytes=0, builtin=True))
            continue
        path = os.path.join(OUT, "%02d_%s.png" % (i, md5))
        if os.path.exists(path) and os.path.getsize(path) > 200:
            items.append(dict(i=i, md5=md5, file=os.path.basename(path),
                              bytes=os.path.getsize(path)))
            continue
        url = meta[md5]["cdn"]
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "MicroMessenger Client"})
            data = urllib.request.urlopen(req, timeout=20).read()
        except Exception as e:
            print("  [%02d] %s FAILED: %s" % (i, md5[:8], e))
            items.append(dict(i=i, md5=md5, file=None, bytes=0, error=str(e)))
            continue
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            print("  [%02d] %s not png (head=%s)" % (i, md5[:8], data[:8].hex()))
        with open(path, "wb") as f:
            f.write(data)
        items.append(dict(i=i, md5=md5, file=os.path.basename(path), bytes=len(data)))
        print("  [%02d] %s ok %d bytes" % (i, md5[:8], len(data)))
    with open(os.path.join(OUT, "index.json"), "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    print("fetched %d / %d with files" % (sum(1 for x in items if x.get("file")), len(items)))
    return items


def sheet(per_sheet=12, cols=4, cell=200):
    from PIL import Image, ImageDraw
    items = json.load(open(os.path.join(OUT, "index.json"), encoding="utf-8"))
    items = [x for x in items if x.get("file")]
    if not items:
        raise SystemExit("no files; run --fetch first")
    rows = (per_sheet + cols - 1) // cols
    made = []
    for s in range(0, len(items), per_sheet):
        chunk = items[s:s + per_sheet]
        im = Image.new("RGB", (cols * cell, rows * cell), "white")
        d = ImageDraw.Draw(im)
        for k, it in enumerate(chunk):
            r, c = divmod(k, cols)
            x0, y0 = c * cell, r * cell
            try:
                p = Image.open(os.path.join(OUT, it["file"])).convert("RGBA")
            except Exception:
                continue
            bg = Image.new("RGBA", (cell, cell), "white")
            p.thumbnail((cell - 30, cell - 30))
            bg.paste(p, ((cell - p.width) // 2, (cell - p.height) // 2), p)
            im.paste(bg.convert("RGB"), (x0, y0))
            d.rectangle([x0, y0, x0 + cell - 1, y0 + cell - 1], outline=(200, 200, 200))
            d.text((x0 + 6, y0 + 4), "#%d" % it["i"], fill=(220, 0, 0))
        path = os.path.join(SHEET_DIR, "sheet%d.png" % (s // per_sheet + 1))
        im.save(path)
        made.append(path)
        print("sheet ->", path)
    return made


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--sheet", action="store_true")
    a = ap.parse_args()
    if a.fetch:
        fetch()
    if a.sheet:
        sheet()


if __name__ == "__main__":
    main()
