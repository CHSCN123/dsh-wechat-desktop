"""搜收藏表情：给几个关键词，列出最像的几条（序号 + 图上文字 + 标签）。

用法：
  python sticker_find.py 夸 得意
  python sticker_find.py 吃白饭
  python sticker_find.py            # 列全部
输出每行：序号  <序号对应的 -Index 值>  图上文字  [标签]

挑选原则（给我自己看）：先按情绪匹配，没有合适的就别硬发，回文字。
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
import sys

INDEX = os.path.join(HERE, "sticker_lab\\sticker_index.json")


def main():
    words = [w.strip().lower() for w in sys.argv[1:] if w.strip()]
    with open(INDEX, encoding="utf-8") as fh:
        doc = json.load(fh)
    items = doc["items"]
    rows = []
    for it in items:
        hay = " ".join([it.get("text", ""), " ".join(it.get("tags", [])), it.get("desc", "")]).lower()
        score = sum(1 for w in words if w in hay)
        rows.append((score, it, hay))
    if words:
        rows = [r for r in rows if r[0] > 0]
        rows.sort(key=lambda r: (-r[0], r[1]["i"]))
    for score, it, _ in rows:
        if it.get("builtin"):
            print("#%-2d (内置，无图)  %s  [%s]" % (it["i"], it.get("text", ""), "/".join(it.get("tags", []))))
            continue
        print("#%-2d  -Index %-2d  %s  [%s]" % (
            it["i"], it["i"], it.get("text", "") or it.get("desc", ""), "/".join(it.get("tags", []))))
    if words and not rows:
        print("没有匹配 %s 的表情" % " ".join(words))


if __name__ == "__main__":
    main()
