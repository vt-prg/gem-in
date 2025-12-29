import argparse
import json
import re
import sys
import time
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse

import requests

ALL_BIDS_URL = "https://bidplus.gem.gov.in/all-bids"
ALL_BIDS_DATA_URL = "https://bidplus.gem.gov.in/all-bids-data"
BASE_URL = "https://bidplus.gem.gov.in"

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

HEADERS = {
    "User-Agent": UA,
    "Referer": ALL_BIDS_URL,
    "Origin": BASE_URL,
    "X-Requested-With": "XMLHttpRequest",
}


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")


def print_one_line_usage_and_exit():
    print("\nUSAGE:")
    print(
        'python gem_latest.py '
        '--keyword "Toner" '
        '--state "Uttar Pradesh" '
        '--pages 2 '
        '--out latest_bids.json '
        '--download-pdf '
        '--pdf-dir pdfs '
        '--pdf-timeout 90'
    )
    print()
    sys.exit(0)


def extract_csrf(html: str) -> str:
    m = re.search(r"csrf_bd_gem_nk'\s*:\s*'([0-9a-f]{16,64})'", html, re.I)
    if m:
        return m.group(1)

    m = re.search(r'name="csrf_bd_gem_nk"\s+value="([0-9a-f]{16,64})"', html, re.I)
    if m:
        return m.group(1)

    raise RuntimeError("CSRF token not found in /all-bids HTML.")


def normalize_ms(value) -> int:
    """
    GeM sometimes returns date sort fields as:
      - int
      - [int]
      - []
      - None
      - numeric string
    """
    if value is None:
        return 0
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, list):
        if not value:
            return 0
        try:
            return int(value[0])
        except Exception:
            return 0
    try:
        return int(value)
    except Exception:
        return 0


def normalize_id(value) -> str:
    """
    Fixes b_id variants:
      8768710 -> "8768710"
      [8768710] -> "8768710"
      " [8768710] " -> "8768710"
      []/None -> ""
    """
    if value is None:
        return ""
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(int(value))
    if isinstance(value, list):
        if not value:
            return ""
        return normalize_id(value[0])

    s = str(value).strip()
    s = s.strip("[](){} \t\r\n\"'")
    m = re.search(r"\d+", s)
    return m.group(0) if m else ""


def bid_doc_url(doc: dict) -> str:
    """
    Mirrors GeM JS:
      default: showbidDocument
      b_bid_type==5 -> showdirectradocumentPdf
      b_bid_type==2 -> showradocumentPdf; if b_eval_type>0 -> list-ra-schedules
    """
    b_id = normalize_id(doc.get("b_id"))
    b_bid_type = doc.get("b_bid_type")
    b_eval_type = doc.get("b_eval_type", 0)

    doc_lbl = "showbidDocument"
    if b_bid_type == 5:
        doc_lbl = "showdirectradocumentPdf"
    elif b_bid_type == 2:
        doc_lbl = "showradocumentPdf"
        if (b_eval_type or 0) > 0:
            doc_lbl = "list-ra-schedules"

    return f"{BASE_URL}/{doc_lbl}/{b_id}" if b_id else ""


def contains_state(doc: dict, state: str) -> bool:
    """
    Broad scan across all string values, because GeM doesn't consistently expose
    a single "consignee_state" field in docs.
    """
    st = state.strip().lower()

    def walk(v):
        if v is None:
            return False
        if isinstance(v, str):
            return st in v.lower()
        if isinstance(v, (int, float, bool)):
            return False
        if isinstance(v, list):
            return any(walk(i) for i in v)
        if isinstance(v, dict):
            return any(walk(i) for i in v.values())
        return False

    return walk(doc)


def fetch_docs(session: requests.Session, csrf: str, page: int, keyword: str) -> list[dict]:
    payload = {
        "page": page,
        "param": {"searchBid": keyword, "searchType": "fullText"},
        "filter": {
            "bidStatusType": "ongoing_bids",
            "byType": "all",
            "highBidValue": "",
            "byEndDate": {"from": "", "to": ""},
            "sort": "Bid-Start-Date-Latest",
        },
    }

    r = session.post(
        ALL_BIDS_DATA_URL,
        headers=HEADERS,
        data={"payload": json.dumps(payload, separators=(",", ":")), "csrf_bd_gem_nk": csrf},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["response"]["response"].get("docs", [])


def safe_filename(name: str) -> str:
    name = name.strip()
    name = re.sub(r"[<>:\"/\\|?*\n\r\t]+", "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:180] if len(name) > 180 else name


def looks_like_pdf(resp: requests.Response) -> bool:
    ctype = (resp.headers.get("Content-Type") or "").lower()
    if "application/pdf" in ctype or "pdf" in ctype:
        return True
    try:
        head = resp.content[:5]
        return head == b"%PDF-"
    except Exception:
        return False


def resolve_pdf_url(
    session: requests.Session,
    doc_url: str,
    pdf_timeout: int,
    debug_dir: Path
) -> tuple[str | None, Path | None]:
    """
    Returns (pdf_url, debug_html_path_if_any)

    Behavior:
    1) GET doc_url. If it returns PDF -> pdf_url = doc_url (ACCEPT as direct PDF URL).
    2) Else treat response as HTML and try to extract a PDF/documentdownload URL.
       If cannot find, save HTML for debugging.
    """
    headers = {
        "User-Agent": UA,
        "Referer": ALL_BIDS_URL,
        "Accept": "application/pdf,text/html,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Connection": "keep-alive",
    }

    r = session.get(doc_url, headers=headers, timeout=pdf_timeout, allow_redirects=True)
    r.raise_for_status()

    # ✅ Case 1: doc_url itself is PDF
    if looks_like_pdf(r):
        return doc_url, None

    html = r.text

    # Case 2: Extract a PDF URL from HTML
    m = re.search(r'href\s*=\s*["\']([^"\']+\.pdf)["\']', html, re.I)
    if m:
        return urljoin(doc_url, m.group(1)), None

    m = re.search(r'["\'](\/bidding\/bid\/documentdownload\/[^"\']+?\.pdf)["\']', html, re.I)
    if m:
        return urljoin(doc_url, m.group(1)), None

    m = re.search(r'["\'](\/bidding\/bid\/documentdownload\/[^"\']+)["\']', html, re.I)
    if m:
        return urljoin(doc_url, m.group(1)), None

    m = re.search(r'["\'](\/bidding\/bid\/documentDownload\/[^"\']+)["\']', html, re.I)
    if m:
        return urljoin(doc_url, m.group(1)), None

    # Save HTML for debugging
    debug_dir.mkdir(parents=True, exist_ok=True)
    debug_path = debug_dir / "docpage_no_pdf_link.html"
    debug_path.write_text(html, encoding="utf-8", errors="ignore")
    return None, debug_path


def download_file(
    session: requests.Session,
    url: str,
    out_path: Path,
    referer: str,
    timeout: int = 60
) -> bool:
    """
    Downloads PDF with correct Referer + cookies (session).
    If server returns HTML/error instead of PDF, saves debug HTML.
    Works even if url == doc_url (showbidDocument/<id> returns PDF bytes).
    """
    headers = {
        "User-Agent": UA,
        "Referer": referer,
        "Accept": "application/pdf,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Connection": "keep-alive",
    }

    try:
        with session.get(url, headers=headers, stream=True, timeout=timeout, allow_redirects=True) as r:
            ctype = (r.headers.get("Content-Type") or "").lower()
            log(f"PDF GET status={r.status_code} content-type={ctype} final_url={r.url}")
            r.raise_for_status()

            # If content-type is not PDF, peek at magic bytes
            if "pdf" not in ctype:
                peek = r.raw.read(5, decode_content=True)
                if peek != b"%PDF-":
                    debug_path = out_path.with_suffix(".html")
                    debug_path.parent.mkdir(parents=True, exist_ok=True)
                    debug_path.write_bytes(peek + r.raw.read(2_000_000))
                    log(f"⚠ Not a PDF response. Saved debug: {debug_path}")
                    return False

                out_path.parent.mkdir(parents=True, exist_ok=True)
                with open(out_path, "wb") as f:
                    f.write(peek)
                    for chunk in r.iter_content(chunk_size=1024 * 128):
                        if chunk:
                            f.write(chunk)
                return True

            # Normal PDF path
            out_path.parent.mkdir(parents=True, exist_ok=True)
            with open(out_path, "wb") as f:
                for chunk in r.iter_content(chunk_size=1024 * 128):
                    if chunk:
                        f.write(chunk)
            return True

    except Exception as e:
        log(f"❌ Download failed: {url} -> {out_path.name} | {e}")
        return False

def normalize_bid_no(value) -> str:
    """
    Fixes b_bid_number variants:
      'GEM/2025/B/7051937' -> 'GEM/2025/B/7051937'
      ['GEM/2025/B/7051937'] -> 'GEM/2025/B/7051937'
      None / [] -> ''
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        if not value:
            return ""
        return normalize_bid_no(value[0])
    return str(value).strip()


def main():
    if "-?" in sys.argv:
        print_one_line_usage_and_exit()

    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--keyword", default="Toner")
    parser.add_argument("--state", default="Uttar Pradesh")
    parser.add_argument("--pages", type=int, default=2)
    parser.add_argument("--out", default="latest_bids.json")
    parser.add_argument("--debug-dates", action="store_true")

    parser.add_argument("--download-pdf", action="store_true", help="Auto-download bid PDF for each matched bid")
    parser.add_argument("--pdf-dir", default="pdfs", help="Directory to save PDFs (default: pdfs)")
    parser.add_argument("--pdf-timeout", type=int, default=90, help="Timeout seconds per PDF download")

    args = parser.parse_args()

    keyword = args.keyword
    state = args.state
    max_pages = max(1, args.pages)

    log("========== GeM Bid Fetch Started ==========")
    log(f"Keyword       : {keyword}")
    log(f"State         : {state}")
    log(f"Pages         : {max_pages}")
    log(f"Output file   : {args.out}")
    log(f"Download PDFs : {args.download_pdf}")
    if args.download_pdf:
        log(f"PDF dir       : {args.pdf_dir}")
        log(f"PDF timeout   : {args.pdf_timeout}")

    session = requests.Session()
    session.headers.update({"User-Agent": UA})

    # 1) Get csrf + cookies
    log("Loading /all-bids to obtain CSRF + cookies")
    r = session.get(ALL_BIDS_URL, headers=HEADERS, timeout=30)
    r.raise_for_status()
    csrf = extract_csrf(r.text)
    log("CSRF obtained")

    results = []
    scanned_total = 0

    for page in range(1, max_pages + 1):
        log(f"Fetching bids page {page}/{max_pages}")
        docs = fetch_docs(session, csrf, page, keyword)
        scanned_total += len(docs)
        log(f"Docs on page {page}: {len(docs)}")
        if not docs:
            break

        for idx, d in enumerate(docs, start=1):
            if not contains_state(d, state):
                continue

            b_id = normalize_id(d.get("b_id"))
            doc_url = bid_doc_url(d)
            bid_no = normalize_bid_no(d.get("b_bid_number"))
            title = d.get("b_title") or d.get("bid_title") or ""

            raw_start = d.get("final_start_date_sort")
            raw_end = d.get("final_end_date_sort")
            start_ms = normalize_ms(raw_start)
            end_ms = normalize_ms(raw_end)

            start_utc = (
                datetime.fromtimestamp(start_ms / 1000, tz=timezone.utc).isoformat()
                if start_ms else ""
            )
            end_utc = (
                datetime.fromtimestamp(end_ms / 1000, tz=timezone.utc).isoformat()
                if end_ms else ""
            )

            if args.debug_dates:
                log(f"DEBUG dates: start_raw={raw_start} start_ms={start_ms} end_raw={raw_end} end_ms={end_ms}")

            log(f"✔ Match: page={page} idx={idx} bid_no={bid_no} b_id={b_id} doc_url={doc_url}")

            item = {
                "b_id": b_id,
                "bid_number": bid_no,
                "title": title,
                "start_utc": start_utc,
                "end_utc": end_utc,
                "doc_url": doc_url,
                "pdf_url": "",
                "pdf_path": "",
            }

            # PDF download section (UPDATED: accept doc_url as direct PDF if it returns PDF)
            if args.download_pdf and doc_url:
                pdf_dir = Path(args.pdf_dir)
                debug_html_dir = pdf_dir / "debug_html"

                try:
                    log(f"Resolving PDF URL (doc_url may already be PDF): {doc_url}")
                    pdf_url, debug_path = resolve_pdf_url(
                        session=session,
                        doc_url=doc_url,
                        pdf_timeout=30,
                        debug_dir=debug_html_dir,
                    )

                    if not pdf_url:
                        log(f"⚠ Could not resolve PDF URL. Debug saved: {debug_path}")
                    else:
                        log(f"PDF URL resolved: {pdf_url}")
                        item["pdf_url"] = pdf_url

                        base = safe_filename(f"{bid_no}_{b_id}") or b_id or f"bid_{page}_{idx}"
                        out_pdf = pdf_dir / f"{base}.pdf"

                        ok = download_file(
                            session=session,
                            url=pdf_url,
                            out_path=out_pdf,
                            referer=doc_url,
                            timeout=args.pdf_timeout,
                        )
                        if ok:
                            log(f"✅ PDF saved: {out_pdf}")
                            item["pdf_path"] = str(out_pdf)

                except Exception as e:
                    log(f"❌ Error resolving/downloading PDF for bid {bid_no} (b_id={b_id}): {e}")

                time.sleep(0.25)

            results.append(item)

        time.sleep(0.2)

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)

    log("========== Completed ==========")
    log(f"Total scanned docs: {scanned_total}")
    log(f"Total matches     : {len(results)}")
    log(f"Saved JSON        : {args.out}")

    for i, r in enumerate(results[:20], 1):
        extra = f" | PDF: {r['pdf_path']}" if r.get("pdf_path") else ""
        log(f"{i}. {r.get('bid_number','')} | {r.get('start_utc','')} | {r.get('doc_url','')}{extra}")


if __name__ == "__main__":
    main()
