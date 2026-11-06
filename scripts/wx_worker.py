"""wx_worker.py - single-process send queue for the desktop WeChat channel (plan A, step 1).

Why: every chat session used to call wx_send.ps1 directly. With several chats
active at once that meant several powershell processes racing for one WeChat
window (wrong-chat sends, stolen focus, heavy CPU). This worker is the only
process allowed to drive the UI: sessions drop a JSON job into send-queue/ and
this loop sends them one by one.

Job file (one JSON object, UTF-8, no BOM):
    {"chat": "猪葛凉", "text": "hi", "actor": "desktop", "verify": true}

Behaviour:
  * queue is FIFO by file mtime, one send at a time, >= THROTTLE seconds apart
  * each job is moved to done/ on success, failed/ on failure (with .error sidecar)
  * sends by calling wx_send.ps1 (still the proven code path for now)
  * writes to activity.jsonl via wx_activity.ps1 so COORD rules keep working
"""
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
QUEUE = os.path.join(HERE, "send-queue")
DONE = os.path.join(QUEUE, "done")
FAILED = os.path.join(QUEUE, "failed")
LOG = os.path.join(HERE, "worker.log")
PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
SEND = os.path.join(HERE, "wx_send.ps1")
THROTTLE = 3.0
IDLE_EXIT = 30 * 60
SEND_TIMEOUT = 180


def log(line):
    stamp = datetime.now().strftime("%m-%d %H:%M:%S")
    with open(LOG, "a", encoding="utf-8") as f:
        f.write("[%s] %s\n" % (stamp, line))


def ensure_dirs():
    for d in (QUEUE, DONE, FAILED):
        os.makedirs(d, exist_ok=True)


def pending_jobs():
    if not os.path.isdir(QUEUE):
        return []
    items = []
    for name in os.listdir(QUEUE):
        if not name.endswith(".json"):
            continue
        path = os.path.join(QUEUE, name)
        try:
            items.append((os.path.getmtime(path), path))
        except OSError:
            continue
    items.sort()
    return [p for _, p in items]


def run_send(job):
    chat = str(job.get("chat") or "").strip()
    text = str(job.get("text") or "")
    if not chat or not text.strip():
        return False, "missing chat or text"
    actor = str(job.get("actor") or "worker")
    args = [PS, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SEND,
            "-Chat", chat, "-Text", text, "-Actor", actor]
    log("send chat=%r chars=%d" % (chat, len(text)))
    try:
        proc = subprocess.run(args, capture_output=True, timeout=SEND_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False, "timeout after %ds" % SEND_TIMEOUT
    out = (proc.stdout or b"").decode("utf-8", "replace") + (proc.stderr or b"").decode("utf-8", "replace")
    ok = proc.returncode == 0 and "NOT FOUND in the chat table" not in out
    detail = "exit=%d" % proc.returncode
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("sent ") or line.startswith("verified") or "WARN" in line or line.startswith("wx_send:"):
            detail += " | " + line
    return ok, detail[:800]


def bot_window_alive():
    """True when a visible WeChat main window exists (the bot client is logged in)."""
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def _cb(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        n = user32.GetWindowTextLengthW(hwnd)
        if n <= 0:
            return True
        buf = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, buf, n + 1)
        if buf.value.strip() in ("微信", "WeChat", "Weixin"):
            found.append(hwnd)
        return True

    user32.EnumWindows(_cb, 0)
    return len(found) > 0


def drain(once=False):
    ensure_dirs()
    blank = os.path.join(QUEUE, "README.txt")
    if not os.path.exists(blank):
        with open(blank, "w", encoding="utf-8") as f:
            f.write("drop {\"chat\":..,\"text\":..} .json files here; wx_worker sends them in order\n")
    last_job_at = time.time()
    log("worker up, queue=%s" % QUEUE)
    while True:
        jobs = pending_jobs()
        if not jobs:
            if once:
                return 0
            if not bot_window_alive():
                log("no WeChat window; client closed -> worker exits")
                return 0
            if time.time() - last_job_at > IDLE_EXIT:
                log("idle for %d min; worker exits" % (IDLE_EXIT // 60))
                return 0
            time.sleep(1.0)
            continue
        for path in jobs:
            name = os.path.basename(path)
            try:
                with open(path, "r", encoding="utf-8-sig") as f:
                    job = json.load(f)
            except Exception as exc:  # unreadable job must not kill the worker
                os.makedirs(FAILED, exist_ok=True)
                shutil.move(path, os.path.join(FAILED, name))
                with open(os.path.join(FAILED, name + ".error"), "w", encoding="utf-8") as f:
                    f.write("bad json: %s" % exc)
                log("bad job %s: %s" % (name, exc))
                continue
            last_job_at = time.time()
            ok, detail = run_send(job)
            target = DONE if ok else FAILED
            os.makedirs(target, exist_ok=True)
            shutil.move(path, os.path.join(target, name))
            if not ok:
                with open(os.path.join(target, name + ".error"), "w", encoding="utf-8") as f:
                    f.write(detail)
            log(("ok " if ok else "FAIL ") + name + " :: " + detail)
            time.sleep(THROTTLE)
        if once:
            return 0


if __name__ == "__main__":
    if "--once" in sys.argv:
        drain(once=True)
    else:
        try:
            drain()
        except KeyboardInterrupt:
            log("worker stopped by user")
