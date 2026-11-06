# wx_park.py - restore + park the WeChat window at 0,0 1500x830 before replying.
import ctypes, ctypes.wintypes as wt, sys, time

W = int(sys.argv[1]) if len(sys.argv) > 1 else 1500
H = int(sys.argv[2]) if len(sys.argv) > 2 else 830

u = ctypes.WinDLL("user32", use_last_error=True)
u.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))

found = []
def cb(h, l):
    cls = ctypes.create_unicode_buffer(256)
    u.GetClassNameW(h, cls, 256)
    if cls.value.endswith("QWindowIcon") and u.IsWindowVisible(h):
        r = wt.RECT(); u.GetWindowRect(h, ctypes.byref(r))
        found.append(h)
    return True

u.EnumWindows(ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)(cb), 0)
if not found:
    print("wx_park: main window not found"); sys.exit(1)
h = found[0]
if u.IsIconic(h):
    u.ShowWindow(h, 9); time.sleep(0.5)
u.ShowWindow(h, 9); time.sleep(0.2)
u.SetWindowPos(h, 0, 0, 0, W, H, 0x0040); time.sleep(0.4)
r = wt.RECT(); u.GetWindowRect(h, ctypes.byref(r))
w, hh = r.right - r.left, r.bottom - r.top
ok = (w == W and hh == H)
print("wx_park: hwnd=%d rect=%d,%d %dx%d ok=%s" % (h, r.left, r.top, w, hh, ok))
sys.exit(0 if ok else 1)
