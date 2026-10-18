#!/usr/bin/env python3
"""Refresh the PsychonautWiki half of data/sources/freeodwiki-en.json.

FreeOD's substance prose is Chinese, and most of it was itself translated *from*
PsychonautWiki. So rather than machine-translating Chinese back into English (a
lossy round-trip), the English layer has two parts:

  This script: for every FreeOD page that has a PsychonautWiki page, pull the real
  PW lead prose via the MediaWiki extracts API (exintro+explaintext, redirects on)
  and store it as that page's English description, attributed to PsychonautWiki.

  Machine translations: the pages PW does not cover are translated from FreeOD's
  Chinese in PsychonautWiki's register, with effect names mapped to canonical PW
  Subjective Effect Index names. Each records the hash of the Chinese it was made
  from, and `freeodwiki_extract.py` lists any whose Chinese has since changed.

`freeodwiki_extract.py` merges the store onto each record, and ingest_freeodwiki()
in sqlite.py honours the source + flag so PW prose is attributed to
`psychonautwiki` and the translations to `freeodwiki`.

Usage:
    python3 pipeline/fetch/brushers/freeodwiki_translate.py
"""

import json
import re
import sqlite3
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://psychonautwiki.org/w/api.php"
UA = "Piru-DataFetcher/1.0 (+https://github.com/kageroumado/piru; first-party data snapshot)"
CJK = re.compile(r"[一-鿿]")

REPO = Path(__file__).resolve().parents[3]
with open(REPO / "data/sources/freeodwiki.json", encoding="utf-8") as fh:
    recs = json.load(fh)

# The ingester resolves each FreeOD page to an English canonical name via its
# override map + alias matching (e.g. 甲基苯丙胺 -> "Methamphetamine"), but a page's
# own title/names may be purely Chinese. Querying PW with only the page's own
# names therefore misses PW-covered substances whose FreeOD page is Chinese-named.
# Seed the best PW candidate from the BUILT DB's canonical name, keyed by slug.
_canon_by_slug = {}
try:
    _db = sqlite3.connect(REPO / "Piru/Data/piru-substances.sqlite")
    for slug, name in _db.execute(
        "SELECT freeodwiki_slug, canonical_name FROM substances WHERE freeodwiki_slug IS NOT NULL"
    ):
        _canon_by_slug[slug] = name
    _db.close()
except sqlite3.Error:
    pass  # DB not built yet; fall back to page-derived names only.


def candidates(rec):
    """English name candidates for a PW title lookup, best first."""
    out = []
    # Resolved canonical name first — it's the same English title PW indexes under.
    canon = _canon_by_slug.get(rec.get("page_slug"))
    if canon and not CJK.search(canon):
        out.append(canon)
    t = (rec.get("title") or "").strip()
    if t and not CJK.search(t) and t not in out:
        out.append(t)
    for n in rec.get("names") or []:
        n = (n or "").strip()
        # drop parenthetical, keep latin-only, length>=2
        n = re.sub(r"[（(].*?[)）]", "", n).strip()
        if n and not CJK.search(n) and len(n) >= 2 and n not in out:
            out.append(n)
    return out[:4]


# Build a query plan: map each candidate title -> list of page_slugs wanting it.
# Query in batches; redirects=1 resolves aliases (Molly -> MDMA).
slug_cands = {r["page_slug"]: candidates(r) for r in recs}
# Round 1 uses the first candidate for each record; later rounds retry the next.
leads = {}  # page_slug -> {title, extract, query}


def fetch_titles(titles):
    """Return {normalized_query_title: extract} for a batch of <=20 titles."""
    params = {
        "action": "query",
        "prop": "extracts",
        "exintro": "1",
        "explaintext": "1",
        "redirects": "1",
        "format": "json",
        "titles": "|".join(titles),
    }
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        d = json.load(resp)
    q = d.get("query", {})
    # Map requested title -> resolved title via normalized + redirects.
    alias = {}
    for n in q.get("normalized", []):
        alias[n["from"]] = n["to"]
    for r in q.get("redirects", []):
        alias[r["from"]] = r["to"]

    def resolve(t):
        seen = set()
        while t in alias and t not in seen:
            seen.add(t)
            t = alias[t]
        return t

    title_extract = {}
    for p in q.get("pages", {}).values():
        if "missing" in p:
            continue
        ex = (p.get("extract") or "").strip()
        if ex:
            title_extract[p["title"]] = ex
    # Map each requested title to an extract through the alias chain.
    res = {}
    for t in titles:
        ex = title_extract.get(resolve(t))
        res[t] = ex if ex and names_itself(t, resolve(t), ex) else None
    return res


def names_itself(query: str, resolved: str, extract: str) -> bool:
    """False when a redirect landed on another compound's article: PsychonautWiki
    sends Dimenhydrinate to Diphenhydramine and Tobacco to Nicotine, and that
    lead describes a different substance. A redirect is kept only when the
    lead's first sentence names what was asked for."""
    if query.casefold() == resolved.casefold():
        return True
    first = extract.split(". ", 1)[0].casefold()
    return query.casefold() in first


remaining = list(slug_cands.keys())
for round_i in range(4):
    # one candidate per still-unmatched record this round
    want = {}  # title -> [slugs]
    for s in remaining:
        if s in leads:
            continue
        cands = slug_cands[s]
        if round_i < len(cands):
            want.setdefault(cands[round_i], []).append(s)
    if not want:
        break
    titles = list(want.keys())
    print(f"round {round_i}: querying {len(titles)} titles", file=sys.stderr)
    for i in range(0, len(titles), 20):
        batch = titles[i : i + 20]
        try:
            res = fetch_titles(batch)
        except Exception as e:  # noqa: BLE001
            print(f"  batch error: {e}", file=sys.stderr)
            time.sleep(2)
            continue
        for t, ex in res.items():
            if ex:
                for s in want[t]:
                    if s not in leads:
                        leads[s] = {"title": t, "extract": ex, "query": t}
        time.sleep(0.5)

STORE = REPO / "data/sources/freeodwiki-en.json"
store = json.loads(STORE.read_text(encoding="utf-8"))
entries = store.setdefault("records", {})
for slug, lead in leads.items():
    entry = entries.setdefault(slug, {})
    entry["description"] = {
        "text": lead["extract"],
        "source": "psychonautwiki",
        "pw_title": lead["title"],
    }
store["records"] = dict(sorted(entries.items()))
STORE.write_text(json.dumps(store, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
missing = [r["page_slug"] for r in recs if r["page_slug"] not in leads]
print(f"\nPW leads matched: {len(leads)} / {len(recs)}")
print(f"no PW page (need a machine translation): {len(missing)}")
