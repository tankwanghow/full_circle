---
name: bank-recon-llm-parser
description: Use when working on Bank Reconciliation statement import — the LLM (Gemini/Claude) parser that extracts transactions and opening/closing balances from bank statement PDFs/CSVs. Covers the multi-page "Balance C/F" carry-forward trap, the whole-statement balance pass, and how different Malaysian banks (Public Bank, RHB, etc.) label balances.
---

# Bank Reconciliation LLM Statement Parser

The Bank Recon feature imports a bank statement (PDF or CSV) and uses an LLM to
extract every transaction line plus the statement's opening and closing balance.
The balances feed `stmt_opening` / `stmt_closing` in the recon and are compared
against the book balances.

## Files

| File | Role |
|------|------|
| `lib/full_circle/bank_reconciliation/llm_parser.ex` | Prompts + batching + balance extraction. **The prompts are the behaviour** — most parsing bugs are prompt bugs, not code bugs. |
| `lib/full_circle/bank_reconciliation/llm_client.ex` | HTTP client. Providers: `claude` (native API), `gemini` (OpenAI-compatible endpoint). PDF sent as base64 document (Claude) / `image_url` data URI (Gemini). |
| `lib/full_circle/bank_reconciliation/pdf_text.ex` | `pdftotext -layout` per page via poppler-utils. Filters out blank pages. |
| `lib/full_circle_web/live/bank_reconciliation_live/index.ex` | Upload handling, `load_llm_settings/1` (from company `settings["llm"]` JSONB), `save_manual_balances` override UI. |

## Parse flow

- **PDF** → `parse_pdf/2`:
  - `PdfText.pages/1` succeeds with **1 page** → `parse_content/2` (single request).
  - succeeds with **N pages** → `parse_pdf_pages/2`: page 1 = first batch (transactions + fallback balances), pages 2..N = continuation batches (transactions only), then a **dedicated whole-statement balance pass** (`extract_balances/4`).
  - `pdftotext` unavailable / no text (scanned PDF) → `parse_pdf_vision/2` sends the raw PDF to the model (`@pdf_prompt`).
- **CSV / text** → `parse/2` → `parse_content/2` (header + batched data lines).

Batching (`@batch_size 100`) exists to avoid **output** token limits (many
transactions → large JSON). It is NOT an input limit.

## THE key gotcha: the multi-page carry-forward trap

Multi-page statements print a **per-page running subtotal** at the bottom of each
page and repeat it at the top of the next:

- Public Bank: `Balance C/F` (bottom) / `Balance B/F` (top).
- RHB: `C/F BALANCE` / `B/F BALANCE`.

**These are NOT the statement opening/closing balance.** The real closing is the
running balance after the *last* transaction of the whole period, usually also
printed in a **summary box** (`Baki Penutup / Closing Balance`, `Ending Balance /
Baki Akhir`) and sometimes as a final row (`Closing Balance In This Statement`).

The original prompt listed `"C/F"` / `"Balance Carried Forward"` as *synonyms* for
the closing balance and told the model "closing = last balance value". On a
multi-page statement the model then returned **page 1's `Balance C/F`** as the
closing — wrong. (Real bug: 2026-June Public Bank statement returned
`2,290,592.78` instead of `1,664,370.46`.)

### The rules (encoded in `@balance_guidance`, shared by every prompt)

1. **Summary-box "Closing Balance" / "Baki Penutup" / "Ending Balance" / "Baki Akhir" is authoritative** — prefer it over any running-column value.
2. **`C/F`, `B/F`, `Carried Forward`, `Brought Forward` are per-page carry-forwards — NEVER use them as opening or closing.** (Even though the *first* page's B/F line often equals the true opening, the summary box supplies opening reliably, so we forbid B/F to avoid picking an intermediate page's B/F.)
3. Opening = balance BEFORE the first transaction (`Opening Balance`, `Balance From Last Statement`, `Baki Pembukaan`, `BAKI AWAL`).
4. Closing = balance AFTER the last transaction of the whole period.
5. Balances are always positive.

## The whole-statement balance pass

`extract_balances/4` sends **all page text joined** in one dedicated call
(`@balance_only_prompt`) that returns only `{opening_balance, closing_balance}`.
Decoupling balances from transaction batching means the closing is found wherever
a bank puts it:

- Public Bank: summary box on page 1 **and** `Closing Balance In This Statement` on the last transaction page (page 5 is a notes page).
- RHB: `Ending Balance` only in the page-1 summary box (last pages are notes); the running column never prints a statement-level total.

Page-1 balances are kept as a **fallback** for any field the dedicated pass leaves
null. Output is a couple of numbers so there is no output-token concern; input is
the full statement (fine for typical sizes; falls back on error).

## When adding support for a new bank

1. Extract the raw text first: `pdftotext -layout <pdf>` — confirm the bank's exact labels for opening/closing and its per-page carry-forward tokens.
2. If the labels aren't already covered, add them to `@balance_guidance` (shared, so all prompts benefit). Prefer adding to the **shared** guidance over per-bank branching.
3. Verify end-to-end with the company's real LLM settings (don't trust unit tests for prompt behaviour):
   ```elixir
   settings = Repo.get!(Company, id).settings["llm"]
   LlmParser.parse_pdf("/path/statement.pdf", settings)
   ```
   Sanity-check: `opening + Σcredits − Σdebits == closing`.
4. `normalize_transaction/1` is the one deterministically unit-testable seam
   (`test/full_circle/bank_reconciliation/llm_parser_test.exs`) — dates (ISO +
   DD-MM-YYYY), amount signs, zero-amount rejection.

## Escape hatch

The upload UI has a `save_manual_balances` form — users can always type the
correct opening/closing if the LLM misreads. A misread balance is a correctness
annoyance, not data loss.
