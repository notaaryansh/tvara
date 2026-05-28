#!/usr/bin/env python3
"""
Sync Notion page metadata into spotlight++'s notion_index.db.

For v1 we index page title + URL + parent-breadcrumb only (no page body,
no database rows). The Swift NotionService does fuzzy title matching and
returns SearchResults that deep-link into the Notion app.

Auth: reads an integration token from one of these locations (first hit wins):
    $NOTION_TOKEN env var
    ~/Library/Application Support/spotlight++/notion_token.txt
    ~/Library/Application Support/spotlight++/.env  (NOTION_TOKEN=...)
    <repo>/.env                                     (NOTION_TOKEN=...)

Setup once on the user's side:
    1. In Notion: Settings → Connections → Develop or manage integrations
    2. + New integration → name it (e.g. "spotlight++") → copy the secret
    3. Paste the secret into the token file above
    4. Share the workspaces/pages you want indexed WITH the integration
       (top-level page → Share menu → Connections → spotlight++)
    5. Run this script: python3 scripts/sync_notion.py

Re-run after creating/renaming pages to refresh the index. Soon we'll
auto-trigger this from the Swift app on a schedule.
"""
import argparse
import json
import os
import re
import sqlite3
import ssl
import sys
import time
import urllib.request
from pathlib import Path

SUPPORT_DIR = Path.home() / "Library/Application Support/spotlight++"
TARGET_DB   = SUPPORT_DIR / "notion_index.db"
PROJECT_ENV = Path(__file__).resolve().parent.parent / ".env"
TOKEN_FILE  = SUPPORT_DIR / "notion_token.txt"
SUPPORT_ENV = SUPPORT_DIR / ".env"

NOTION_API     = "https://api.notion.com/v1/search"
NOTION_VERSION = "2022-06-28"   # latest stable as of writing


def load_token() -> str:
    if t := os.environ.get("NOTION_TOKEN"):
        return t.strip()
    for path in (TOKEN_FILE, SUPPORT_ENV, PROJECT_ENV):
        if not path.exists():
            continue
        text = path.read_text()
        # bare token file
        if path == TOKEN_FILE:
            t = text.strip()
            if t:
                return t
            continue
        # dotenv
        for line in text.splitlines():
            m = re.match(r'(?:export\s+)?NOTION_TOKEN\s*=\s*"?([^"\n]+)"?', line)
            if m:
                return m.group(1).strip()
    sys.exit(
        "NOTION_TOKEN not found.\n"
        "Create an integration at https://www.notion.so/profile/integrations,\n"
        f"then paste the secret into: {TOKEN_FILE}"
    )


def ssl_ctx() -> ssl.SSLContext:
    try:
        import certifi   # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def open_db() -> sqlite3.Connection:
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(TARGET_DB)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS pages (
            id               TEXT PRIMARY KEY,
            title            TEXT NOT NULL,
            url              TEXT NOT NULL,
            parent_type      TEXT,
            parent_id        TEXT,
            last_edited_time TEXT,
            indexed_at       INTEGER NOT NULL
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_pages_title ON pages(title COLLATE NOCASE)"
    )
    conn.execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    """)
    conn.commit()
    return conn


def fetch_page_batch(token: str, cursor: str | None) -> dict:
    body = {
        "page_size": 100,
        # No filter — we want both pages AND databases (but not their rows).
        # Database rows are indexed separately when we add database support.
    }
    if cursor:
        body["start_cursor"] = cursor

    req = urllib.request.Request(
        NOTION_API,
        data=json.dumps(body).encode(),
        headers={
            "Authorization":   f"Bearer {token}",
            "Notion-Version":  NOTION_VERSION,
            "Content-Type":    "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, context=ssl_ctx(), timeout=30) as r:
        return json.loads(r.read())


def extract_title(item: dict) -> str:
    """Notion's title lives under properties for pages, or in a `title`
    field for databases. Either way it's a list of rich-text fragments."""
    if item.get("object") == "database":
        frags = item.get("title", [])
        return "".join(f.get("plain_text", "") for f in frags).strip()
    props = item.get("properties", {})
    # Pages have a property whose type is "title" — name varies (usually
    # "Name" or "title"). Find it dynamically.
    for prop in props.values():
        if prop.get("type") == "title":
            return "".join(f.get("plain_text", "") for f in prop.get("title", [])).strip()
    return ""


def parent_info(item: dict) -> tuple[str, str]:
    p = item.get("parent", {})
    t = p.get("type", "")
    pid = (p.get("page_id")
           or p.get("database_id")
           or p.get("workspace")
           or p.get("block_id")
           or "")
    return (t, str(pid))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-pages", type=int, default=None,
                    help="cap pages for testing")
    args = ap.parse_args()

    token = load_token()
    conn = open_db()
    now_ts = int(time.time())

    cursor = None
    total = 0
    while True:
        try:
            data = fetch_page_batch(token, cursor)
        except urllib.error.HTTPError as e:
            sys.exit(f"Notion API error {e.code}: {e.read().decode()[:300]}")
        except Exception as e:
            sys.exit(f"Notion API failed: {e}")

        results = data.get("results", [])
        if not results:
            break

        rows = []
        for item in results:
            page_id = item.get("id")
            if not page_id:
                continue
            title = extract_title(item) or "(untitled)"
            url = item.get("url", f"https://www.notion.so/{page_id.replace('-', '')}")
            ptype, pid = parent_info(item)
            rows.append((
                page_id, title, url, ptype, pid,
                item.get("last_edited_time"), now_ts,
            ))

        conn.executemany("""
            INSERT OR REPLACE INTO pages
                (id, title, url, parent_type, parent_id, last_edited_time, indexed_at)
            VALUES (?,?,?,?,?,?,?)
        """, rows)
        conn.commit()
        total += len(rows)
        print(f"  +{len(rows)} (total {total})")

        if args.max_pages and total >= args.max_pages:
            break
        if not data.get("has_more"):
            break
        cursor = data.get("next_cursor")
        # Rate limit: Notion allows 3 req/s.
        time.sleep(0.4)

    # Track last successful sync.
    conn.execute(
        "INSERT OR REPLACE INTO metadata(key, value) VALUES('last_sync', ?)",
        (str(now_ts),),
    )
    conn.commit()
    conn.close()
    print(f"done. {total} pages indexed → {TARGET_DB}")


if __name__ == "__main__":
    main()
