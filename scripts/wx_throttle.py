"""微信自动化的全局节流 + 互斥锁。

为什么要这个：脚本一快，微信小号就会卡住甚至假死。
规则：
  * 同一时刻只允许一个微信自动化动作（文件锁），避免多个脚本同时抢鼠标。
  * 两次动作之间至少隔 MIN_GAP 秒。
  * 一分钟内最多 MAX_PER_MIN 次动作。
"""
import json
import os
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(ROOT, "throttle-state.json")
LOCK = os.path.join(ROOT, "throttle.lock")

MIN_GAP = 2.5          # 任意两次动作之间的最小间隔（秒）
MAX_PER_MIN = 8        # 每分钟最多动作数
LOCK_STALE = 45        # 锁超过这么久认为被遗弃（秒）


def _read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _write(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f)


def _acquire_lock(timeout=60):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return True
        except FileExistsError:
            try:
                age = time.time() - os.path.getmtime(LOCK)
            except OSError:
                age = 0
            if age > LOCK_STALE:
                try:
                    os.remove(LOCK)
                except OSError:
                    pass
                continue
            time.sleep(0.3)
    return False


def _release_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def wait_turn(tag=""):
    """阻塞直到允许执行下一个动作。"""
    if not _acquire_lock():
        raise RuntimeError("wx_throttle: 拿不到动作锁，可能有脚本卡住了")
    st = _read(STATE) or {"last": 0, "events": []}
    now = time.time()
    events = [e for e in st.get("events", []) if now - e < 60]
    # 间隔
    gap = now - float(st.get("last", 0))
    if gap < MIN_GAP:
        time.sleep(MIN_GAP - gap)
    # 每分钟配额
    if len(events) >= MAX_PER_MIN:
        oldest = min(events)
        sleep_for = 60 - (now - oldest) + 0.2
        if sleep_for > 0:
            time.sleep(sleep_for)
        now = time.time()
        events = [e for e in events if now - e < 60]
    now = time.time()
    events.append(now)
    _write(STATE, {"last": now, "events": events})
    return True


def done():
    _release_lock()
