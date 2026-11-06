"""用 wx_sticker.py 的定位/点击基建发文字：还原窗口 -> 点输入框 -> 清空 -> 粘贴 -> 回车。"""
import argparse
import ctypes
import importlib.util
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("ws", r"C:\Users\LX\.dsh\weixin\wcdb\wx_sticker.py")
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

spec2 = importlib.util.spec_from_file_location("thr", r"C:\Users\LX\.dsh\weixin\wcdb\wx_throttle.py")
thr = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(thr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    thr.wait_turn("send")
    try:
        _send(args)
    finally:
        thr.done()


def _send(args):
    ws.set_dpi_aware()
    u = ws.user32
    hwnd, pid = ws.resolve_hwnd()
    hwnd = ws.pick_main(hwnd, pid)

    if u.IsIconic(ctypes.c_void_p(hwnd)) or (u.GetWindowRect and False):
        u.ShowWindow(hwnd, 9)
        time.sleep(0.5)
    if u.IsZoomed(ctypes.c_void_p(hwnd)):
        # 最大化时键盘事件进不去微信，先还原
        u.ShowWindow(hwnd, 9)
        time.sleep(0.6)

    r = ws.RECT()
    u.GetWindowRect(hwnd, ctypes.byref(r))
    W, H = r.right - r.left, r.bottom - r.top
    if W <= 0 or H <= 0:
        u.ShowWindow(hwnd, 9)
        time.sleep(0.6)
        u.GetWindowRect(hwnd, ctypes.byref(r))
        W, H = r.right - r.left, r.bottom - r.top

    # 聚焦
    fg = u.GetForegroundWindow()
    if fg != hwnd:
        tid = ctypes.windll.kernel32.GetCurrentThreadId()
        ftid = u.GetWindowThreadProcessId(ctypes.c_void_p(fg), None)
        u.AttachThreadInput(tid, ftid, True)
        u.SetForegroundWindow(ctypes.c_void_p(hwnd))
        u.AttachThreadInput(tid, ftid, False)
        time.sleep(0.5)

    ix = int(r.left + W * 0.47)
    iy = int(r.top + H * 0.79)
    ws.real_click(ix, iy, 0.4)

    def ctrl(key):
        u.keybd_event(0x11, 0, 0, 0); time.sleep(0.04)
        u.keybd_event(key, 0, 0, 0); time.sleep(0.04)
        u.keybd_event(key, 0, 2, 0); time.sleep(0.04)
        u.keybd_event(0x11, 0, 2, 0); time.sleep(0.08)

    ctrl(0x41)                 # 全选
    u.keybd_event(0x2E, 0, 0, 0); time.sleep(0.04)
    u.keybd_event(0x2E, 0, 2, 0); time.sleep(0.15)

    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", r"C:\Users\LX\.dsh\weixin\wcdb\wx_clip.ps1",
                    "-Text", args.text], check=False)
    time.sleep(0.35)
    ctrl(0x56)                 # 粘贴
    time.sleep(0.7)

    before, _ = ws.capture_window(hwnd)
    u.keybd_event(0x0D, 0x1C, 0, 0); time.sleep(0.06)
    u.keybd_event(0x0D, 0x1C, 2, 0)
    time.sleep(0.9)

    after, _ = ws.capture_window(hwnd)
    ws.save_debug(after, "sendshot")
    print("sent via py: %d chars, window %dx%d" % (len(args.text), W, H))


if __name__ == "__main__":
    main()

