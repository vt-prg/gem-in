import argparse
import json
import re
import time
from pathlib import Path
from datetime import datetime
from typing import Optional, List, Set, Tuple

import requests
from bs4 import BeautifulSoup

BASE = "https://bidplus.gem.gov.in"
ALL_BIDS_URL = f"{BASE}/all-bids"
BID_VIEW_URL = f"{BASE}/bidding/bid/getBidResultView/{{bid_id}}"
DOC_URL = f"{BASE}/showbidDocument/{{bid_id}}"

DOWNLOAD_DIR = Path("downloads")
STATE_FILE = Path("state.json")

HEADERS = {
    "User-Agent": "Mozilla/5.0",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
}

DATE_FORMAT = "%d-%m-%Y %H:%M:%S"


# ------------------ STATE ------------------

def load_state(default_hours_ago: int) -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {
        "last_seen_epoch": int(time.time()) - default_hours_ago * 3600,
        "seen_bid_ids": []
    }

def save_state(state: dict):
    STATE_FILE.write_text(json.dumps(state, indent=2))


# ------------------ PARSING ------------------

def extract_bid_ids(html: str) -> List[str]:
    ids = set(re.findall(r"/getBidResultView/(\d+)", html))
    ids |= set(re.findall(r"/showbidDocument/(\d+)", html))
    return sorted({i for i in ids if i.isdigit()}, key=int, reverse=True)

def extract_bid_start_epoch(html: str) -> Optional[int]:
    m = re.search(r"Bid Start Date\s*/\s*Time:\s*([0-9:\-\s]+)", html)
    if not m:
        return None
    try:
        dt = datetime.strptime(m.group(1).strip(), DATE_FORMAT)
        return int(dt.timestamp())
    except Exception:
        return None

def extract_category_text(html: str) -> str:
    text = BeautifulSoup(html, "lxml").get_text(" ", strip=True)
    m = re.search(r"\bCategory\b\s*[:\-]?\s*([^|]{0,120})", text, re.IGNORECASE)
    return m.group(1).strip() if m else ""

def extract_consignee_state(html: str) -> str:
    text = BeautifulSoup(html, "lxml").get_text(" ", strip=True)

    patterns = [
        r"\bState\s*[:\-]?\s*([A-Za-z ]{3,})",
        r"\bConsignee\s+State\s*[:\-]?\s*([A-Za-z ]{3,})",
        r"\bLocation\s*/\s*State\s*[:\-]?\s*([A-Za-z ]{3,})",
    ]

    for pat in patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            return m.group(1).strip().upper()

    return ""


# ------------------ FILTERS ------------------

def matches_keyword(text: str, keyword: Optional[str], mode: str) -> bool:
    if not keyword:
        return True
    hay = text.lower()
    needle = keyword.lower()
    if mode == "exact":
        return needle in hay
    return all(t in hay for t in needle.split())

def matches_category(category_text: str, category_filter: Optional[str]) -> bool:
    if not category_filter:
        return True
    return category_filter.lower() in category_text.lower()

def matches_state(consignee_state: str, allowed_states: Optional[List[str]]) -> bool:
    if not allowed_states:
        return True
    return consignee_state.upper() in {s.upper() for s in allowed_states}


# ------------------ DOWNLOAD ------------------

def download_bid_pdf(session: requests.Session, bid_id: str) -> bool:
    url = DOC_URL.format(bid_id=bid_id)
    referer = BID_VIEW_URL.format(bid_id=bid_id)

    r = session.get(url, headers={**HEADERS, "Referer": referer}, timeout=60)
    if r.status_code == 200 and "pdf" in r.headers.get("content-type", "").lower():
        path = DOWNLOAD_DIR / f"bid_{bid_id}.pdf"
        path.write_bytes(r.content)
        print(f"✅ PDF saved: {path}")
        return True

    print(f"⚠️ No PDF for bid {bid_id}")
    return False


# ------------------ MAIN ------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keyword", "-k")
    ap.add_argument("--mode", choices=["contains", "exact"], default="contains")
    ap.add_argument("--category", "-c")
    ap.add_argument("--state", action="append",
                    help="Allowed consignee state (repeatable). Example: --state KARNATAKA")
    ap.add_argument("--max-pages", type=int, default=10)
    ap.add_argument("--delay", type=float, default=0.4)
    ap.add_argument("--default-hours-ago", type=int, default=10)
    args = ap.parse_args()

    DOWNLOAD_DIR.mkdir(exist_ok=True)

    state = load_state(args.default_hours_ago)
    last_seen_epoch = state["last_seen_epoch"]
    seen_ids: Set[str] = set(state["seen_bid_ids"])

    session = requests.Session()
    session.headers.update(HEADERS)

    all_ids: List[str] = []

    for page_no in range(1, args.max_pages + 1):
        url = ALL_BIDS_URL if page_no == 1 else f"{ALL_BIDS_URL}?page={page_no}"
        r = session.get(url, timeout=60)
        if r.status_code != 200:
            break

        ids = extract_bid_ids(r.text)
        if not ids:
            break

        all_ids.extend(ids)
        time.sleep(args.delay)

    newest_epoch = last_seen_epoch

    for bid_id in dict.fromkeys(all_ids):
        if bid_id in seen_ids:
            continue

        r = session.get(BID_VIEW_URL.format(bid_id=bid_id), timeout=60)
        if r.status_code != 200:
            continue

        html = r.text
        start_epoch = extract_bid_start_epoch(html)
        if not start_epoch or start_epoch <= last_seen_epoch:
            continue

        page_text = BeautifulSoup(html, "lxml").get_text(" ", strip=True)
        category_text = extract_category_text(html)
        consignee_state = extract_consignee_state(html)

        if not matches_keyword(page_text, args.keyword, args.mode):
            continue
        if not matches_category(category_text, args.category):
            continue
        if not matches_state(consignee_state, args.state):
            continue

        print(f"✔ Matched bid {bid_id} | State={consignee_state}")
        download_bid_pdf(session, bid_id)

        seen_ids.add(bid_id)
        newest_epoch = max(newest_epoch, start_epoch)
        time.sleep(args.delay)

    state["seen_bid_ids"] = sorted(seen_ids, key=int)
    state["last_seen_epoch"] = newest_epoch
    save_state(state)

    print("✅ Done. State updated.")


if __name__ == "__main__":
    main()
