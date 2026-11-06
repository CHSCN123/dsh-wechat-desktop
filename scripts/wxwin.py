import ctypes

def list_windows(pid):
    u = ctypes.WinDLL("user32")
    out = []
    EP = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    class RECT(ctypes.Structure):
        _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long), ("r", ctypes.c_long), ("b", ctypes.c_long)]
    def cb(h, lp):
        p = ctypes.c_ulong(); u.GetWindowThreadProcessId(h, ctypes.byref(p))
        if p.value == pid and u.IsWindowVisible(h):
            r = RECT(); u.GetWindowRect(h, ctypes.byref(r))
            cls = ctypes.create_unicode_buffer(128); u.GetClassNameW(h, cls, 128)
            out.append((int(h), r.r - r.l, r.b - r.t, r.l, r.t, cls.value))
        return True
    u.EnumWindows(EP(cb), 0)
    return out
