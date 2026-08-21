#!/usr/bin/env python3
"""Reconstruct Xero pay-run documents from an Account Transactions report export.

Xero posts pay runs via system journals the API cannot expose
(accounting.journals.read is not grantable to this app), so the importer's
XCATCHUP journals were absorbing them as year lumps. This script rebuilds the
individual documents from the Xero UI "Account Transactions" report (xlsx,
all accounts, whole history) and writes priv/xero_import/extra_docs.json,
which Snapshot.read merges into the snapshot:

  Wage Payable Invoice rows  -> pseudo ACCPAY bills   (FC PurInvoice)
  Payable Payment on AP      -> pseudo payments        (FC Payment + matcher)
  Payslip rows               -> pseudo SPEND bank txns funded FROM Wages
                                Payable (FC Payment: debit Wages, credit WP)
  Wages Payable payouts      -> pseudo SPEND bank txns funded from bank/cash
                                hitting Wages Payable (FC Payment)
  Adjustment rows            -> pseudo manual journals (FC Journal)

Depreciation (source-less) and End of Period rows are excluded: XDEP and
XCLOSE journals already post those.

Usage:
  python3 scripts/xero_wage_reconstruct.py \
      "<report.xlsx>" priv/xero_import/golden_husbandry priv/xero_import/extra_docs.json
"""

import collections
import datetime
import json
import sys

import openpyxl

WAGE_PAY_DESC = "Payment: Wage Payable Invoice"


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_lines(xlsx_path):
    wb = openpyxl.load_workbook(xlsx_path, read_only=True)
    ws = wb.active
    account = None
    lines = []
    for row in ws.iter_rows(min_row=7, values_only=True):
        if not row or all(v is None for v in row):
            continue
        d, s = row[0], row[1]
        if isinstance(d, str) and not s:
            if not d.startswith("Total ") and d not in ("Opening Balance", "Closing Balance"):
                account = d
            continue
        if isinstance(d, datetime.datetime):
            lines.append(
                {
                    "account": account,
                    "date": d.date(),
                    "source": s,
                    "contact": row[2],
                    "desc": row[3],
                    "inv": row[4],
                    "ref": row[5],
                    "debit": round(row[6] or 0, 2),
                    "credit": round(row[7] or 0, 2),
                }
            )
    return lines


def account_maps(snapshot_dir):
    accounts = json.load(open(f"{snapshot_dir}/accounts.json"))
    by_name = {}
    for a in accounts:
        name = a.get("Name")
        if name:
            by_name[name] = {"code": a.get("Code"), "id": a.get("AccountID") or a.get("AccountId")}
    return by_name


def contact_map(snapshot_dir):
    contacts = json.load(open(f"{snapshot_dir}/contacts.json"))
    return {c.get("Name"): c.get("ContactID") for c in contacts if c.get("Name")}


def slug(text):
    return "".join(ch for ch in str(text) if ch.isalnum())[:20]


def iso(d):
    return d.isoformat()


def main():
    if len(sys.argv) != 4:
        die(__doc__)
    xlsx_path, snapshot_dir, out_path = sys.argv[1:4]

    lines = load_lines(xlsx_path)
    acc = account_maps(snapshot_dir)
    known_contacts = contact_map(snapshot_dir)

    def account_code(name):
        info = acc.get(name)
        if not info or not info.get("code"):
            die(f"account not found or has no code in accounts.json: {name!r}")
        return info["code"]

    def account_id(name):
        info = acc.get(name)
        if not info or not info.get("id"):
            die(f"account not found in accounts.json: {name!r}")
        return info["id"]

    new_contacts = {}

    def contact_id(name):
        if name in known_contacts:
            return known_contacts[name]
        if name not in new_contacts:
            new_contacts[name] = f"xdoc-{slug(name).lower()}"
        return new_contacts[name]

    invoices, payments, bank_txns, journals = [], [], [], []

    # ---- 1. Wage Payable Invoice -> ACCPAY bills, grouped by (PR ref, contact)
    wpi = [l for l in lines if l["source"] == "Wage Payable Invoice"]
    bills = collections.defaultdict(list)
    for l in wpi:
        if not (l["inv"] and str(l["inv"]).startswith("PR-")):
            die(f"wage invoice line without PR number: {l}")
        bills[(l["inv"], l["contact"])].append(l)

    bill_id_by_key = {}
    for (pr, contact), rows in sorted(bills.items()):
        debit_rows = [r for r in rows if r["debit"] > 0]
        ap_credits = [r for r in rows if r["credit"] > 0]
        if any(r["account"] != "Accounts Payable" for r in ap_credits):
            die(f"unexpected credit account in wage bill {pr}/{contact}")
        total = round(sum(r["credit"] for r in ap_credits), 2)
        line_sum = round(sum(r["debit"] for r in debit_rows), 2)
        if abs(total - line_sum) >= 0.005:
            die(f"wage bill {pr}/{contact} unbalanced: lines {line_sum} vs AP {total}")
        inv_id = f"xwpi-{pr.lower()}-{slug(contact).lower()}"
        bill_id_by_key[(pr, contact)] = inv_id
        invoices.append(
            {
                "Type": "ACCPAY",
                "Status": "AUTHORISED",
                "CurrencyCode": "MYR",
                "InvoiceID": inv_id,
                "InvoiceNumber": f"{pr}-{slug(contact)[:10].upper()}",
                "Reference": f"{pr} {contact}",
                "Date": iso(rows[0]["date"]),
                "DueDate": iso(rows[0]["date"]),
                "Total": total,
                "LineAmountTypes": "NoTax",
                "Contact": {"ContactID": contact_id(contact)},
                "LineItems": [
                    {
                        "AccountCode": account_code(r["account"]),
                        "Description": str(r["ref"] or r["desc"] or pr)[:200],
                        "Quantity": 1,
                        "UnitAmount": r["debit"],
                        "LineAmount": r["debit"],
                        "TaxType": "NONE",
                    }
                    for r in debit_rows
                ],
            }
        )

    # ---- 2. Statutory payments: AP debits grouped by (contact, date)
    wage_pay = [l for l in lines if l["source"] == "Payable Payment" and l["desc"] == WAGE_PAY_DESC]
    ap_debits = [l for l in wage_pay if l["account"] == "Accounts Payable" and l["debit"] > 0]
    funds_credits = [
        l for l in wage_pay if l["credit"] > 0 and l["account"] != "Accounts Payable"
        and l["account"] != "Wages Payable"
    ]
    wp_debits = [l for l in wage_pay if l["account"] == "Wages Payable" and l["debit"] > 0]
    wp_funds = [
        l for l in funds_credits if (l["contact"], l["date"]) in
        {(w["contact"], w["date"]) for w in wp_debits}
    ]

    # funds account per (contact, date) group
    def funds_for(contact, date, amount_needed, pool):
        cands = [l for l in pool if l["contact"] == contact and l["date"] == date]
        accounts_used = sorted({l["account"] for l in cands})
        if len(accounts_used) == 1:
            return accounts_used[0]
        if not accounts_used:
            die(f"no funds credit found for payment group {contact} {date}")
        exact = [l for l in cands if abs(l["credit"] - amount_needed) < 0.005]
        if len({l["account"] for l in exact}) == 1:
            return exact[0]["account"]
        die(f"ambiguous funds account for {contact} {date}: {accounts_used}")

    ap_funds_pool = [l for l in funds_credits if l not in wp_funds]
    pay_n = 0
    for l in sorted(ap_debits, key=lambda x: (x["date"], x["contact"], str(x["ref"]), x["debit"])):
        pr = str(l["ref"])
        if not pr.startswith("PR-"):
            die(f"AP wage payment without PR reference: {l}")
        key = (pr, l["contact"])
        if key not in bill_id_by_key:
            die(f"wage payment references unknown bill {key}")
        pay_n += 1
        funds = funds_for(l["contact"], l["date"], l["debit"], ap_funds_pool)
        payments.append(
            {
                "PaymentID": f"XWPAY-{pay_n:04d}",
                "Status": "AUTHORISED",
                "Date": iso(l["date"]),
                "Amount": l["debit"],
                "Account": {"AccountID": account_id(funds)},
                "Invoice": {"InvoiceID": bill_id_by_key[key]},
            }
        )

    # ---- 3. Payslips -> SPEND funded from Wages Payable, line Wages and Salaries
    slips = [l for l in lines if l["source"] == "Payslip" and l["debit"] > 0]
    slip_credits = [l for l in lines if l["source"] == "Payslip" and l["credit"] > 0]
    if round(sum(l["debit"] for l in slips), 2) != round(sum(l["credit"] for l in slip_credits), 2):
        die("payslip debit/credit totals differ")
    slip_n = 0
    for l in sorted(slips, key=lambda x: (x["date"], str(x["inv"]), str(x["contact"]))):
        slip_n += 1
        bank_txns.append(
            {
                "Type": "SPEND",
                "Status": "AUTHORISED",
                "BankTransactionID": f"xslip-{slip_n:04d}",
                "BankTransactionNumber": f"XWSLIP-{slip_n:04d}",
                "Date": iso(l["date"]),
                "Total": l["debit"],
                "Reference": f"Payslip {l['inv']} {l['contact']}"[:200],
                "BankAccount": {"AccountID": account_id("Wages Payable")},
                "Contact": {"ContactID": contact_id(l["contact"])},
                "LineAmountTypes": "NoTax",
                "LineItems": [
                    {
                        "AccountCode": account_code(l["account"]),
                        "Description": f"Payslip {l['inv']}"[:200],
                        "Quantity": 1,
                        "UnitAmount": l["debit"],
                        "LineAmount": l["debit"],
                        "TaxType": "NONE",
                    }
                ],
            }
        )

    # ---- 4. Wage payouts: Wages Payable debits grouped by (contact, date)
    payouts = collections.defaultdict(list)
    for l in wp_debits:
        payouts[(l["contact"], l["date"])].append(l)
    out_n = 0
    for (contact, date), rows in sorted(payouts.items(), key=lambda kv: (kv[0][1], str(kv[0][0]))):
        total = round(sum(r["debit"] for r in rows), 2)
        funds = funds_for(contact, date, total, wp_funds)
        out_n += 1
        bank_txns.append(
            {
                "Type": "SPEND",
                "Status": "AUTHORISED",
                "BankTransactionID": f"xwout-{out_n:04d}",
                "BankTransactionNumber": f"XWOUT-{out_n:04d}",
                "Date": iso(date),
                "Total": total,
                "Reference": f"{rows[0]['ref'] or 'Wage payout'} {contact}"[:200],
                "BankAccount": {"AccountID": account_id(funds)},
                "Contact": {"ContactID": contact_id(contact)},
                "LineAmountTypes": "NoTax",
                "LineItems": [
                    {
                        "AccountCode": account_code("Wages Payable"),
                        "Description": str(r["ref"] or "Wage payout")[:200],
                        "Quantity": 1,
                        "UnitAmount": r["debit"],
                        "LineAmount": r["debit"],
                        "TaxType": "NONE",
                    }
                    for r in rows
                ],
            }
        )

    # ---- 5. Adjustments -> manual journals per date
    adjustments = collections.defaultdict(list)
    for l in lines:
        if l["source"] == "Adjustment":
            adjustments[l["date"]].append(l)
    for date, rows in sorted(adjustments.items()):
        net = round(sum(r["debit"] - r["credit"] for r in rows), 2)
        if abs(net) >= 0.005:
            die(f"adjustment lines on {date} do not balance: {net}")
        journals.append(
            {
                "JournalNumber": f"XADJ-{iso(date)}",
                "Narration": "Xero reconciliation adjustment",
                "Status": "POSTED",
                "Date": iso(date),
                "JournalLines": [
                    {
                        "AccountCode": account_code(r["account"]),
                        "LineAmount": round(r["debit"] - r["credit"], 2),
                        "Description": str(r["desc"] or "Reconciliation adjustment")[:200],
                    }
                    for r in rows
                ],
            }
        )

    extra = {
        "contacts": [
            {"ContactID": cid, "Name": name} for name, cid in sorted(new_contacts.items())
        ],
        "invoices": invoices,
        "payments": payments,
        "bank_transactions": bank_txns,
        "manual_journals": journals,
    }
    with open(out_path, "w") as f:
        json.dump(extra, f, indent=1)

    wages_by_year = collections.defaultdict(float)
    for l in lines:
        if l["source"] in ("Payslip", "Wage Payable Invoice") and l["account"] == "Wages and Salaries":
            wages_by_year[l["date"].year] += l["debit"] - l["credit"]
    print(f"written {out_path}")
    print(f"  new contacts:      {len(new_contacts)}")
    print(f"  wage bills:        {len(invoices)}")
    print(f"  bill payments:     {len(payments)}")
    print(f"  payslip payments:  {slip_n}")
    print(f"  wage payouts:      {out_n}")
    print(f"  adjustment jrnls:  {len(journals)}")
    print("  wages by year:", {y: round(v, 2) for y, v in sorted(wages_by_year.items())})


if __name__ == "__main__":
    main()
