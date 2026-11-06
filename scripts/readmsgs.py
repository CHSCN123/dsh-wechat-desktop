"""Read WeChat 4.x decrypted message DB for one conversation.

Usage:
  python readmsgs.py --user wxid_xxx [--limit 20] [--db-dir DIR]
  python readmsgs.py --user wxid_xxx --watch [--interval 2]
"""
import argparse
import hashlib
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
import sqlite3
import sys
import time
from datetime import datetime

try:
    from compression import zstd  # Python 3.14+
except Exception:  # pragma: no cover
    zstd = None

CT_ZSTD = 4


def unpack(value, ct):
    """message_content is zstd-compressed when WCDB_CT_message_content == 4."""
    if value is None:
        return ""
    if isinstance(value, (bytes, bytearray)):
        if ct == CT_ZSTD and zstd is not None:
            try:
                return zstd.decompress(bytes(value)).decode("utf-8", "replace")
            except Exception:
                pass
        return bytes(value).decode("utf-8", "replace")
    return str(value)


def open_db(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def name2id(con, table="Name2Id"):
    """rowid is the id real_sender_id refers to; name order is NOT rowid order."""
    out = {}
    try:
        for rid, user in con.execute(f"select rowid, user_name from {table} order by rowid"):
            out[rid] = user
    except sqlite3.Error:
        pass
    return out


def self_username(db_dir):
    """The logged-in account's wxid (account dir name is <wxid>_<suffix>)."""
    for candidate in (os.environ.get("WECHAT_SELF_WXID"),):
        if candidate:
            return candidate
    return None


def msg_table(db_path, user):
    con = open_db(db_path)
    suffix = hashlib.md5(user.encode()).hexdigest()
    want = f"Msg_{suffix}"
    tabs = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
    con.close()
    return want if want in tabs else None


def rows(db_path, user, limit=30):
    table = msg_table(db_path, user)
    if not table:
        return []
    con = open_db(db_path)
    ids = name2id(con)
    me = self_username(os.path.dirname(os.path.dirname(db_path)))
    q = f'select * from "{table}" order by sort_seq desc limit {int(limit)}'
    out = []
    for row in con.execute(q):
        d = dict(row)
        text = unpack(d.get("message_content"), d.get("WCDB_CT_message_content"))
        src = unpack(d.get("source"), d.get("WCDB_CT_source"))
        sender = ids.get(d.get("real_sender_id"), str(d.get("real_sender_id")))
        out.append(
            {
                "local_id": d.get("local_id"),
                "server_id": d.get("server_id"),
                "type": d.get("local_type"),
                "time": d.get("create_time"),
                "time_str": datetime.fromtimestamp(d.get("create_time") or 0).strftime("%m-%d %H:%M:%S"),
                "sender": sender,
                "is_self": (me is None and d.get("real_sender_id") == 1) or (me is not None and sender == me),
                "text": text,
                "source": src,
            }
        )
    con.close()
    out.reverse()
    return out


def fmt(m):
    who = "我" if m["is_self"] else m["sender"]
    t = m["type"]
    body = m["text"].replace("\n", " ")
    if t == 1:
        pass
    elif t == 3:
        body = "[图片] " + body[:120]
    elif t == 47:
        body = "[表情] " + body[:120]
    elif t == 34:
        body = "[语音]"
    elif t == 43:
        body = "[视频]"
    elif t == 49:
        body = "[卡片/链接] " + body[:100]
    elif t == 10000:
        body = "[系统] " + body[:80]
    return f'{m["time_str"]} {who}: {body[:220]}'


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
    # --expect mode: compare inside python so console encoding never matters
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", required=True)
    ap.add_argument("--db-dir", default=os.environ.get("WX_DECRYPTED_DIR") or os.path.join(HERE, "decrypted"))
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--expect", default=None, help="print FOUND/NOTFOUND instead of rows; used by wx_send.ps1 to verify a send")
    args = ap.parse_args()
    if args.expect is not None:
        try:
            db_path = os.path.join(args.db_dir, "message", "message_0.db")
            rs = rows(db_path, args.user, args.limit)
        except Exception:
            print("NOTFOUND")
            return 1
        want = args.expect.strip()
        for r in rs:
            if r.get("is_self") and want in (r.get("text") or ""):
                print("FOUND")
                return 0
        print("NOTFOUND")
        return 1
    db_path = os.path.join(args.db_dir, "message", "message_0.db")
    data = rows(db_path, args.user, args.limit)
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=1))
        return
    for m in data:
        print(fmt(m))


if __name__ == "__main__":
    sys.exit(main())
