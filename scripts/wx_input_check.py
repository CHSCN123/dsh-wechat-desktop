"""输入框像素对比：paste 前后比一下，判断字有没有进去（不依赖 OCR）。"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
import sys, os, json, importlib.util
from PIL import ImageChops, Image
spec=importlib.util.spec_from_file_location("ws", os.path.join(HERE, "wx_sticker.py"))
ws=importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
ws.set_dpi_aware()

STATE=os.path.join(HERE, "input_before.png")

def grab_input(hwnd):
    img,(L,T,W,H)=ws.capture_window(hwnd)
    return img.crop((int(W*0.16), int(H*0.62), int(W*0.95), int(H*0.95)))

def main():
    hwnd=int(sys.argv[1]); action=sys.argv[2]
    img=grab_input(hwnd)
    if action=="save":
        img.save(STATE); print('{"ok":true}')
    else:
        if not os.path.exists(STATE):
            print('{"ok":false,"error":"no baseline"}'); return
        base=Image.open(STATE).convert("L")
        cur=img.convert("L")
        if base.size!=cur.size: cur=cur.resize(base.size)
        diff=ImageChops.difference(base,cur)
        changed=sum(1 for p in diff.getdata() if p>25)
        print(json.dumps({"ok": changed>800, "changed": changed}))

main()

