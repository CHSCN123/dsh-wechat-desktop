"""Watch one WeChat 4.x conversation and emit new messages as structured lines.

Watches the encrypted message_0.db-wal for changes, decrypts ONLY that single
DB (message/message_0.db is small, so this is ~milliseconds), and prints any
row newer than the last seen local_id.

Machine-readable output for the DSH plugin:
    @@MSG {"local_id": ..., "text": ..., ...}     one inbound (peer) message
Human-readable line for the log:
    [NEW] 10-24 11:07:12 wxid_xxx: 真的假的

Messages the logged-in account sent itself are reported as [NEW] but never as
@@MSG, so the plugin cannot answer its own echo.

  python watch.py --user wxid_hmqh1bam6y3422 [--interval 1.5] [--out inbox.jsonl]
"""
import argparse
import contextlib
import io
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# The DSH plugin reads our stdout as UTF-8. Without this, Windows Python writes
# the console code page (cp936 here) into the pipe and every Chinese message
# reaches the agent as mojibake.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass
sys.path.insert(0, HERE)
from readmsgs import rows, fmt  # noqa: E402
import wcdb_key_tool_windows as KEYTOOL  # noqa: E402

MSG_DB_REL = os.path.join("message", "message_0.db")
DEFAULT_DB_DIR = r"D:\LeStoreDownload\xwechat_files\wxid_kn207qgkufhp29_5794\db_storage"
DEFAULT_DEC = r"C:\Users\LX\.dsh\weixin\wcdb\decrypted"


def load_enc_key(keys_file, rel=MSG_DB_REL):
    with open(keys_file, encoding="utf-8") as f:
        keys = json.load(f)
    info = KEYTOOL._get_key_info(keys, rel)
    if not info:
        return None
    return bytes.fromhex(info["enc_key"])


def decrypt_message_db(src_dir, dec_dir, enc_key):
    """Decrypt just message_0.db; the tool prints progress, so swallow it."""
    src = os.path.join(src_dir, MSG_DB_REL)
    dst = os.path.join(dec_dir, MSG_DB_REL)
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink):
        ok = KEYTOOL._decrypt_database(src, dst, enc_key)
    return ok, sink.getvalue()


def acquire_single_instance(lock_path):
    """Hold an exclusive lock for the lifetime of the process.

    The DSH plugin can be mounted more than once in a live session (a market
    hot-mount plus a bundle row, or two mounts in a row), and every instance
    spawns its own watcher — each of which would deliver the same message to
    the agent again. One OS-level lock keeps exactly one watcher running.

    The lock must sit on byte 0 of a NON-append handle: with "a+b" every process
    locks a byte at its own EOF offset, so nothing ever conflicts.
    """
    try:
        handle = open(lock_path, "r+b")
    except FileNotFoundError:
        handle = open(lock_path, "w+b")
    try:
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        handle.close()
        return None
    except ImportError:  # not Windows: best effort
        pass
    handle.seek(0)
    handle.truncate()
    handle.write(str(os.getpid()).encode("ascii"))
    handle.flush()
    # Diagnostics only: the locked file itself cannot be read by anything else.
    try:
        with open(lock_path + ".owner", "w", encoding="ascii") as owner:
            owner.write(str(os.getpid()))
    except OSError:
        pass
    return handle


def emit_selftest(flag_path, user):
    """Debug hook: if <HERE>/selftest.flag exists, drop a synthetic peer message.

    Used to prove the "wake an agent and send the reply back" half of the
    pipeline without waiting for a real person to type. The flag is consumed so
    it fires exactly once.
    """
    if not os.path.exists(flag_path):
        return
    try:
        os.remove(flag_path)
    except OSError:
        return
    payload = {
        "local_id": 0,
        "server_id": 0,
        "type": 1,
        "time": int(time.time()),
        "time_str": time.strftime("%m-%d %H:%M:%S"),
        "sender": user,
        "is_self": False,
        "text": "[selftest] 这条是装置自检消息，用来验证自动唤醒与自动回信。",
        "source": "<selftest/>",
    }
    log("[watch] selftest message emitted")
    log("@@MSG " + json.dumps(payload, ensure_ascii=False))


def log(s):
    print(s, flush=True)


EXTRA_CHATS = os.path.join(HERE, "watched-chats.txt")


def extra_chats():
    """Extra conversations to watch, one `wxid|nickname` per line.

    Friends added later must be listed here or their messages never reach the
    agent: the main chat is the CLI `--user`, everything else lives in this file.
    """
    try:
        with open(EXTRA_CHATS, encoding="utf-8") as f:
            out = []
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                out.append(line.split("|")[0].strip())
            return out
    except OSError:
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", required=True)
    ap.add_argument("--interval", type=float, default=1.5)
    ap.add_argument("--out", default=os.path.join(HERE, "inbox.jsonl"))
    ap.add_argument("--db-dir", default=DEFAULT_DB_DIR)
    ap.add_argument("--dec", default=DEFAULT_DEC)
    ap.add_argument("--keys", default=os.path.join(HERE, "key.json"))
    ap.add_argument("--limit", type=int, default=8)
    ap.add_argument("--lock", default=os.path.join(HERE, "watch.lock"))
    args = ap.parse_args()

    lock = acquire_single_instance(args.lock)
    if lock is None:
        # Another watcher already owns the lock. Exit with code 3: the plugin
        # treats 3 as "another instance owns the watcher; standing down" and does
        # NOT respawn us, so exactly one watcher stays alive (no idle spinner
        # burning DB queries every 1.5s).
        log("[watch] another instance holds the lock; standing down")
        return 3

    enc = load_enc_key(args.keys)
    if enc is None:
        log("[watch] no key for " + MSG_DB_REL)
        return 2

    wal = os.path.join(args.db_dir, "message", "message_0.db-wal")
    log(f"[watch] user={args.user} db={args.db_dir}")
    seen_map = {}
    last_stamp = None
    fails = 0
    while True:
        try:
            stamp = (os.path.getsize(wal), os.path.getmtime(wal)) if os.path.exists(wal) else None
            if stamp != last_stamp:
                ok, out = decrypt_message_db(args.db_dir, args.dec, enc)
                if not ok:
                    fails += 1
                    if fails % 20 == 1:
                        log("[watch] decrypt failed: " + out.strip()[-160:])
                else:
                    fails = 0
                    last_stamp = stamp
                    chats = [args.user] + [c for c in extra_chats() if c != args.user]
                    for chat in chats:
                        try:
                            msgs = rows(os.path.join(args.dec, MSG_DB_REL), chat, args.limit)
                        except Exception as inner:  # missing table / bad row
                            log(f"[watch] skip {chat}: {type(inner).__name__}: {inner}")
                            continue
                        if not msgs:
                            continue
                        newest = max(m["local_id"] for m in msgs)
                        if chat not in seen_map:
                            seen_map[chat] = newest
                            who = "main" if chat == args.user else chat
                            log(f"[watch] baseline {who} local_id={newest} ({len(msgs)} recent)")
                            continue
                        base = seen_map[chat]
                        for m in [x for x in msgs if x["local_id"] > base]:
                            seen_map[chat] = max(seen_map[chat], m["local_id"])
                            m["chat"] = chat
                            log("[NEW] " + fmt(m))
                            if not m.get("is_self"):
                                log("@@MSG " + json.dumps(m, ensure_ascii=False))
                            with open(args.out, "a", encoding="utf-8") as f:
                                f.write(json.dumps(m, ensure_ascii=False) + "\n")
            # The selftest hook must fire even when nothing changes: check it
            # every tick, not only inside the WAL-change branch.
            emit_selftest(os.path.join(HERE, "selftest.flag"), args.user)
        except Exception as e:  # keep the watcher alive
            log(f"[watch] error: {type(e).__name__}: {e}")
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())

