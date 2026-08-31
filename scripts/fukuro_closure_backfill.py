#!/usr/bin/env python3
"""Backfill Lightspeed (Vend) register-closure invoices into Golden Husbandry's Xero.

Lightspeed's native Xero integration broke on 30 Jan 2026 (closure #2344); this
script replays the unsent closures as ACCREC invoices + payments, replicating the
exact document shape the integration used to post (see INV-2349 and earlier).

Closure data is harvested from the Lightspeed web session (Claude-in-Chrome) into
priv/xero_import/fukuro_backfill/closures_regular.csv and closures_anomalies.json.

Usage:
  python3 scripts/fukuro_closure_backfill.py auth      # one-time browser consent (adds write scopes)
  python3 scripts/fukuro_closure_backfill.py dry-run   # build + validate plan, check Xero for dupes
  python3 scripts/fukuro_closure_backfill.py post      # create invoices + payments (asks to confirm)
  python3 scripts/fukuro_closure_backfill.py verify    # re-read from Xero and reconcile

Auth notes: shares priv/xero_import/.credentials with the GH import tool. `auth`
re-consents with the import's read scopes PLUS accounting.invoices and
accounting.payments (granular write; the broad accounting.transactions scope is
not grantable to this app). Refresh tokens are single-use: every refresh here
persists the rotated token immediately, same as the import tool.
"""

import csv
import json
import secrets
import sys
import time
import urllib.parse
import urllib.request
import webbrowser
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CRED_PATH = ROOT / "priv/xero_import/.credentials"
DATA_DIR = ROOT / "priv/xero_import/fukuro_backfill"
PLAN_PATH = DATA_DIR / "plan.json"
RESULT_PATH = DATA_DIR / "post_result.json"

TOKEN_URL = "https://identity.xero.com/connect/token"
AUTHORIZE_URL = "https://login.xero.com/identity/connect/authorize"
REDIRECT_URI = "http://localhost:4099/callback"  # WAF rejects literal 127.0.0.1
API = "https://api.xero.com/api.xro/2.0"

READ_SCOPES = [
    "accounting.settings.read",
    "accounting.contacts.read",
    "accounting.invoices.read",
    "accounting.payments.read",
    "accounting.banktransactions.read",
    "accounting.manualjournals.read",
    "accounting.reports.trialbalance.read",
    "assets.read",
]
WRITE_SCOPES = ["accounting.invoices", "accounting.payments"]

# From the historical closure invoices in the GH snapshot (e.g. INV-2349).
CONTACT_ID = "3ab66d2f-0ee5-4e1e-992a-9e100a5fdf39"  # Fukuro - Main Register
ACCT_SALES = "200"
ACCT_FLOAT = "10005"  # Cash In Register
ACCT_ROUNDING = "411"  # Rounding Errors/Discrepancies
ACCT_SHORTFALL = "431"
PAYMENT_ACCOUNTS = {  # payment reference -> Xero AccountID
    "Cash": "f748fff9-602b-41c0-8f9f-3abbd9ba6523",  # 10004 Cash In Hand
    "Touch N Go": "0310ae69-16fe-4c54-a054-9f632e9f4a52",  # TNG Touch N Go Fund
    "Cash Rounding": "eb865dbb-15c8-4024-b2b0-e5633cc71cdf",  # 411
    "Online Transfer": "3729e7dd-4a80-4bdb-b99f-d94e29c008b8",  # PBBCURR
    "Debit Card": "3729e7dd-4a80-4bdb-b99f-d94e29c008b8",  # PBBCURR
    "Visa Credit Card": "3729e7dd-4a80-4bdb-b99f-d94e29c008b8",  # PBBCURR
    "Master Credit Card": "3729e7dd-4a80-4bdb-b99f-d94e29c008b8",  # PBBCURR
}

FIRST_INV_NUMBER = 2350  # history ends at INV-2349 (closure #2343)

MONTHS = {m: i for i, m in enumerate(
    "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}


def d(x):
    return Decimal(str(x or "0"))


def parse_closed(s):
    # "30 Jan 2026 16:27" -> "2026-01-30"
    day, mon, year = s.split(" ")[:3]
    return f"{year}-{MONTHS[mon]:02d}-{int(day):02d}"


# ---------- credentials ----------

def load_creds():
    raw = {}
    for line in CRED_PATH.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            raw[k.strip()] = v.strip()
    return raw


def save_creds(raw):
    keys = ["XERO_CLIENT_ID", "XERO_CLIENT_SECRET", "XERO_ACCESS_TOKEN", "XERO_REFRESH_TOKEN"]
    body = "".join(f"{k}={raw.get(k, '')}\n" for k in keys if raw.get(k))
    tmp = CRED_PATH.with_suffix(".tmp")
    tmp.write_text(body)
    tmp.replace(CRED_PATH)


def http(method, url, body=None, headers=None, form=False):
    data = None
    headers = dict(headers or {})
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        payload = e.read().decode()
        try:
            payload = json.loads(payload)
        except Exception:
            pass
        return e.code, payload


def refresh_token(creds):
    import base64
    basic = base64.b64encode(f"{creds['XERO_CLIENT_ID']}:{creds['XERO_CLIENT_SECRET']}".encode()).decode()
    status, tok = http("POST", TOKEN_URL,
                       {"grant_type": "refresh_token", "refresh_token": creds["XERO_REFRESH_TOKEN"]},
                       {"Authorization": f"Basic {basic}"}, form=True)
    if status != 200:
        sys.exit(f"token refresh failed ({status}): {tok}\nRun `auth` again.")
    creds["XERO_ACCESS_TOKEN"] = tok["access_token"]
    creds["XERO_REFRESH_TOKEN"] = tok["refresh_token"]
    save_creds(creds)  # single-use refresh tokens: persist immediately
    return creds


def tenant_id(creds):
    status, conns = http("GET", "https://api.xero.com/connections", headers=auth_headers(creds))
    if status != 200:
        sys.exit(f"connections failed ({status}): {conns}")
    gh = [c for c in conns if "Golden Husbandry" in c.get("tenantName", "")]
    if not gh:
        sys.exit(f"Golden Husbandry not in connections: {[c.get('tenantName') for c in conns]}")
    return gh[0]["tenantId"]


def auth_headers(creds, tenant=None):
    h = {"Authorization": f"Bearer {creds['XERO_ACCESS_TOKEN']}", "Accept": "application/json"}
    if tenant:
        h["Xero-tenant-id"] = tenant
    return h


# ---------- auth (browser consent) ----------

def cmd_auth():
    creds = load_creds()
    state = secrets.token_urlsafe(16)
    scopes = READ_SCOPES + WRITE_SCOPES + ["offline_access"]
    url = AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "response_type": "code",
        "client_id": creds["XERO_CLIENT_ID"],
        "redirect_uri": REDIRECT_URI,
        "scope": " ".join(scopes),
        "state": state,
    })
    code_box = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if q.get("state", [""])[0] == state and "code" in q:
                code_box["code"] = q["code"][0]
                msg = b"Consent received. You can close this tab."
            else:
                msg = b"Missing/invalid code or state."
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(msg)

        def log_message(self, *a):
            pass

    server = HTTPServer(("127.0.0.1", 4099), Handler)
    print("Opening browser for Xero consent (adds invoice+payment write scopes).")
    print("If the browser doesn't open, visit:\n" + url)
    webbrowser.open(url)
    while "code" not in code_box:
        server.handle_request()
    server.server_close()

    import base64
    basic = base64.b64encode(f"{creds['XERO_CLIENT_ID']}:{creds['XERO_CLIENT_SECRET']}".encode()).decode()
    status, tok = http("POST", TOKEN_URL,
                       {"grant_type": "authorization_code", "code": code_box["code"],
                        "redirect_uri": REDIRECT_URI},
                       {"Authorization": f"Basic {basic}"}, form=True)
    if status != 200:
        sys.exit(f"token exchange failed ({status}): {tok}")
    creds["XERO_ACCESS_TOKEN"] = tok["access_token"]
    creds["XERO_REFRESH_TOKEN"] = tok["refresh_token"]
    save_creds(creds)
    print("Consent stored. Scopes:", tok.get("scope", ""))


# ---------- plan building ----------

def load_closures():
    closures = []
    with open(DATA_DIR / "closures_regular.csv") as f:
        for row in csv.reader(f, delimiter=";"):
            seq, closed, sales, disc, c, t, r, o, dc, v, m = row
            pays = {"Cash": d(c), "Touch N Go": d(t), "Cash Rounding": d(r),
                    "Online Transfer": d(o), "Debit Card": d(dc),
                    "Visa Credit Card": d(v), "Master Credit Card": d(m)}
            closures.append({"seq": int(seq), "date": parse_closed(closed),
                             "sales": d(sales), "payments": pays,
                             "floats": Decimal(250), "extra_lines": []})
    for a in json.loads((DATA_DIR / "closures_anomalies.json").read_text()):
        pays = {k: d(v) for k, v in a.get("payments", {}).items()}
        closures.append({"seq": a["seq"], "date": parse_closed(a["closed"]),
                         "sales": d(a["sales"]), "payments": pays,
                         "floats": Decimal(a.get("floats", 250)),
                         "extra_lines": [
                             {"description": x["description"], "amount": d(x["amount"]),
                              "account": x["account"]}
                             for x in a.get("extra_lines", [])]})
    closures.sort(key=lambda c: c["seq"])
    return closures


def build_plan(closures):
    plan = []
    inv_no = FIRST_INV_NUMBER
    for c in closures:
        rounding = c["payments"].get("Cash Rounding", Decimal(0))
        pay_out = []
        for ref, amt in c["payments"].items():
            if ref == "Cash Rounding":
                if amt > 0:
                    pay_out.append({"reference": ref, "amount": amt})
            elif amt != 0:
                pay_out.append({"reference": ref, "amount": amt})

        lines = []
        if c["sales"] != 0:
            lines.append({"description": f"Sales Account Code: {ACCT_SALES}",
                          "amount": c["sales"], "account": ACCT_SALES})
        # Negative Cash Rounding (till gained on 5-sen rounding) is handled by the
        # residual guard below: it books a single positive Rounding Errors line,
        # matching the historical integration's shape (e.g. INV-2141).
        for x in c["extra_lines"]:
            lines.append(dict(x))
        # residual guard: lines must equal payments exactly
        residual = sum(p["amount"] for p in pay_out) - sum(l["amount"] for l in lines)
        if residual != 0:
            lines.append({"description": "Rounding Errors/Discrepancies",
                          "amount": residual, "account": ACCT_ROUNDING})
            if abs(residual) > Decimal("1.00"):
                sys.exit(f"closure {c['seq']}: residual {residual} exceeds 1.00 — refusing")
        lines.append({"description": "Closing float", "amount": -c["floats"], "account": ACCT_FLOAT})
        lines.append({"description": "Opening float", "amount": c["floats"], "account": ACCT_FLOAT})

        total = sum(l["amount"] for l in lines)
        assert total == sum(p["amount"] for p in pay_out), c["seq"]
        plan.append({"seq": c["seq"], "date": c["date"],
                     "invoice_number": f"INV-{inv_no}",
                     "total": str(total),
                     "lines": [{**l, "amount": str(l["amount"])} for l in lines],
                     "payments": [{**p, "amount": str(p["amount"])} for p in pay_out]})
        inv_no += 1
    return plan


# ---------- xero calls ----------

def existing_closure_refs(creds, tenant):
    refs, numbers, page = set(), set(), 1
    while True:
        url = f"{API}/Invoices?" + urllib.parse.urlencode(
            {"ContactIDs": CONTACT_ID, "page": page, "pageSize": 500})
        status, body = http("GET", url, headers=auth_headers(creds, tenant))
        if status == 429:
            time.sleep(int_retry(body))
            continue
        if status != 200:
            sys.exit(f"invoice listing failed ({status}): {body}")
        invs = body.get("Invoices", [])
        for i in invs:
            if i.get("Status") in ("VOIDED", "DELETED"):
                continue
            if i.get("Reference"):
                refs.add(str(i["Reference"]))
            if i.get("InvoiceNumber"):
                numbers.add(i["InvoiceNumber"])
        if len(invs) < 500:
            return refs, numbers
        page += 1


def int_retry(body):
    return 5


def post_batches(creds, tenant, path, key, items, batch=40):
    created = []
    for i in range(0, len(items), batch):
        chunk = items[i:i + batch]
        while True:
            status, body = http("POST", f"{API}/{path}?summarizeErrors=false",
                                {key: chunk}, auth_headers(creds, tenant))
            if status == 429:
                print("  rate limited, waiting 60s…")
                time.sleep(60)
                continue
            break
        if status != 200:
            sys.exit(f"{path} batch failed ({status}): {json.dumps(body)[:2000]}")
        for el in body.get(key, []):
            errs = el.get("ValidationErrors") or []
            if errs:
                sys.exit(f"{path} validation error on {el.get('InvoiceNumber') or el.get('Reference')}: {errs}")
            created.append(el)
        print(f"  {path}: {len(created)}/{len(items)}")
        time.sleep(1.2)
    return created


def invoice_payload(p):
    return {
        "Type": "ACCREC",
        "Contact": {"ContactID": CONTACT_ID},
        "Date": p["date"],
        "DueDate": p["date"],
        "InvoiceNumber": p["invoice_number"],
        "Reference": str(p["seq"]),
        "Status": "AUTHORISED",
        "LineAmountTypes": "Inclusive",
        "LineItems": [
            {"Description": l["description"], "Quantity": 1.0,
             "UnitAmount": float(l["amount"]), "AccountCode": l["account"],
             "TaxType": "NONE"}
            for l in p["lines"]
        ],
    }


# ---------- commands ----------

def cmd_dry_run():
    closures = load_closures()
    plan = build_plan(closures)
    creds = refresh_token(load_creds())
    tenant = tenant_id(creds)
    refs, numbers = existing_closure_refs(creds, tenant)
    dupes = [p for p in plan if str(p["seq"]) in refs or p["invoice_number"] in numbers]
    todo = [p for p in plan if p not in dupes]
    PLAN_PATH.write_text(json.dumps({"tenant": tenant, "plan": todo}, indent=1))
    total = sum(Decimal(p["total"]) for p in todo)
    n_pay = sum(len(p["payments"]) for p in todo)
    print(f"closures in dataset : {len(plan)}")
    print(f"already in Xero     : {len(dupes)}  {[p['seq'] for p in dupes][:10]}")
    print(f"to post             : {len(todo)} invoices ({todo[0]['invoice_number']}..{todo[-1]['invoice_number']}), {n_pay} payments")
    print(f"total sales value   : RM {total}")
    print(f"date range          : {todo[0]['date']} .. {todo[-1]['date']}")
    print(f"plan written to     : {PLAN_PATH}")
    zeroes = [p for p in todo if Decimal(p['total']) == 0]
    print(f"zero-total closures : {[p['seq'] for p in zeroes]}")


def cmd_post():
    if not PLAN_PATH.exists():
        sys.exit("run dry-run first")
    stored = json.loads(PLAN_PATH.read_text())
    plan = stored["plan"]
    total = sum(Decimal(p["total"]) for p in plan)
    print(f"About to create {len(plan)} invoices (RM {total}) + "
          f"{sum(len(p['payments']) for p in plan)} payments in Golden Husbandry's LIVE Xero.")
    if input("Type 'post' to continue: ").strip() != "post":
        sys.exit("aborted")

    creds = refresh_token(load_creds())
    tenant = tenant_id(creds)
    # re-check dupes right before writing
    refs, numbers = existing_closure_refs(creds, tenant)
    plan = [p for p in plan if str(p["seq"]) not in refs and p["invoice_number"] not in numbers]
    print(f"{len(plan)} invoices after fresh dupe check")

    invoices = [invoice_payload(p) for p in plan]
    created = post_batches(creds, tenant, "Invoices", "Invoices", invoices)
    id_by_number = {i["InvoiceNumber"]: i["InvoiceID"] for i in created}

    payments = []
    for p in plan:
        inv_id = id_by_number.get(p["invoice_number"])
        if not inv_id:
            sys.exit(f"no InvoiceID returned for {p['invoice_number']}")
        for pay in p["payments"]:
            payments.append({
                "Invoice": {"InvoiceID": inv_id},
                "Account": {"AccountID": PAYMENT_ACCOUNTS[pay["reference"]]},
                "Date": p["date"],
                "Amount": float(pay["amount"]),
                "Reference": pay["reference"],
            })
    created_pays = post_batches(creds, tenant, "Payments", "Payments", payments)
    RESULT_PATH.write_text(json.dumps({
        "invoices": [{"number": i["InvoiceNumber"], "id": i["InvoiceID"]} for i in created],
        "payments": len(created_pays),
    }, indent=1))
    print(f"done: {len(created)} invoices, {len(created_pays)} payments. Run `verify`.")


def cmd_verify():
    stored = json.loads(PLAN_PATH.read_text())
    plan = {p["invoice_number"]: p for p in stored["plan"]}
    creds = refresh_token(load_creds())
    tenant = tenant_id(creds)
    page, seen, problems = 1, {}, []
    while True:
        url = f"{API}/Invoices?" + urllib.parse.urlencode(
            {"ContactIDs": CONTACT_ID, "page": page, "pageSize": 500})
        status, body = http("GET", url, headers=auth_headers(creds, tenant))
        if status != 200:
            sys.exit(f"listing failed ({status})")
        invs = body.get("Invoices", [])
        for i in invs:
            if i.get("InvoiceNumber") in plan:
                seen[i["InvoiceNumber"]] = i
        if len(invs) < 500:
            break
        page += 1
    for number, p in sorted(plan.items()):
        i = seen.get(number)
        if not i:
            problems.append(f"{number}: MISSING")
            continue
        if d(i["Total"]) != d(p["total"]).copy_abs() and d(i["Total"]) != d(p["total"]):
            problems.append(f"{number}: total {i['Total']} != planned {p['total']}")
        # Xero auto-marks zero-total AUTHORISED invoices as PAID, so both end PAID.
        if i["Status"] != "PAID":
            problems.append(f"{number}: status {i['Status']} != PAID")
        if d(i.get("AmountDue")) != 0 and Decimal(p["total"]) != 0:
            problems.append(f"{number}: amount due {i.get('AmountDue')}")
    print(f"checked {len(plan)} planned invoices, found {len(seen)} in Xero")
    if problems:
        print("PROBLEMS:")
        for x in problems:
            print(" ", x)
        sys.exit(1)
    print("verify OK: all posted, totals match, all non-zero invoices fully paid")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    {"auth": cmd_auth, "dry-run": cmd_dry_run, "post": cmd_post, "verify": cmd_verify}.get(
        cmd, lambda: sys.exit(__doc__))()
