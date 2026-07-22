#!/usr/bin/env python3
"""Parse Egg Est Left ODS weekly books (sheets 1-7, P1-P7) → egg_dow_books.json.

Uses SECTION 1 only (first Customer/Supplier table on each sheet). That is the
block whose day totals feed the Est sheet SO rows.

Usage:
  python3 priv/repo/seeds/parse_egg_ods_to_json.py \\
      "/path/to/Egg Est Left 2026(New)1.ods" \\
      [priv/repo/seeds/egg_dow_books.json]
"""

from __future__ import annotations

import json
import os
import sys
import zipfile
import xml.etree.ElementTree as ET

GRADE_COLS = ["AA", "A", "B", "C", "D", "E", "F", "Cr", "W"]

NS = {
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "text": "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}


def cell_text(cell) -> str:
    texts = ["".join(p.itertext()) for p in cell.findall(".//text:p", NS)]
    t = " ".join(texts).strip()
    if t:
        return t
    return cell.get("{urn:oasis:names:tc:opendocument:xmlns:office:1.0}value") or ""


def all_rows(sheet, max_cols: int = 12):
    out = []
    for row in sheet.findall("table:table-row", NS):
        rep = int(
            row.get(
                "{urn:oasis:names:tc:opendocument:xmlns:table:1.0}number-rows-repeated",
                "1",
            )
        )
        cells = []
        c_i = 0
        for cell in row:
            tag = cell.tag.split("}")[-1]
            if tag not in ("table-cell", "covered-table-cell"):
                continue
            crep = int(
                cell.get(
                    "{urn:oasis:names:tc:opendocument:xmlns:table:1.0}number-columns-repeated",
                    "1",
                )
            )
            val = cell_text(cell)
            for _ in range(min(crep, max_cols - c_i)):
                cells.append(val)
                c_i += 1
                if c_i >= max_cols:
                    break
            if c_i >= max_cols:
                break
        if not any(cells):
            out.append(cells)
            continue
        for _ in range(min(rep, 1)):
            out.append(cells)
    return out


def parse_num(v) -> int:
    if v is None or v == "":
        return 0
    try:
        return int(float(str(v).replace(",", "").strip()))
    except ValueError:
        return 0


def parse_section1(sheets, sheet_name: str):
    """First Customer/Supplier table only. Named rows after Total are kept (e.g. HockSoon)."""
    rows = all_rows(sheets[sheet_name], 12)
    lines = []
    in_table = False
    past_total = False
    blank_run = 0

    for r in rows:
        name0 = (r[0] or "").strip() if r else ""
        low = name0.lower()

        if low in ("customer", "supplier"):
            if in_table:
                break  # section 2
            in_table = True
            past_total = False
            blank_run = 0
            continue

        if not in_table:
            continue

        if low == "total":
            past_total = True
            blank_run = 0
            continue

        if not name0:
            blank_run += 1
            continue

        if blank_run >= 1 and lines and not past_total:
            lines.append({"separator": True, "name": "", "quantities": {}})
        blank_run = 0

        qtys = {}
        for i, g in enumerate(GRADE_COLS):
            col = i + 1
            if col < len(r):
                n = parse_num(r[col])
                if n != 0:
                    qtys[g] = n

        lines.append({"name": name0, "quantities": qtys, "separator": False})

    return lines


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    ods_path = argv[1]
    out_path = (
        argv[2]
        if len(argv) > 2
        else os.path.join(os.path.dirname(__file__), "egg_dow_books.json")
    )

    with zipfile.ZipFile(ods_path) as z:
        content = z.read("content.xml")

    root = ET.fromstring(content)
    sheets = {
        s.get("{urn:oasis:names:tc:opendocument:xmlns:table:1.0}name"): s
        for s in root.findall(".//table:table", NS)
    }

    books = {
        "sales": {},
        "purchase": {},
        "meta": {
            "source": os.path.basename(ods_path),
            "section": 1,
            "note": "Section 1 of sheets 1-7 / P1-P7. Blank gaps become separators.",
        },
    }

    for d in range(1, 8):
        books["sales"][str(d)] = parse_section1(sheets, str(d))
        books["purchase"][str(d)] = parse_section1(sheets, f"P{d}")

    for kind in ("sales", "purchase"):
        for d in range(1, 8):
            lines = books[kind][str(d)]
            named = [l for l in lines if not l.get("separator")]
            seps = len(lines) - len(named)
            total_qty = sum(sum(l.get("quantities", {}).values()) for l in named)
            print(f"{kind} {d}: {len(named)} names, {seps} seps, qty_sum={total_qty}")

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(books, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"Wrote {out_path} ({os.path.getsize(out_path)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
