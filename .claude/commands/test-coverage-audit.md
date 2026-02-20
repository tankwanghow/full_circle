Audit test coverage and identify gaps: $ARGUMENTS

If no argument given, audit the entire project. If a specific context or feature is given, focus on that.

## Instructions

### 1. Inventory All Context Modules
Read each context module in `lib/full_circle/` and list all public functions.

### 2. Inventory All Test Files
Read each test file in `test/full_circle/` and `test/full_circle_web/` and list all test cases.

### 3. Cross-Reference
For each public function, determine if it has test coverage:
- Direct test (function is called in a test)
- Indirect test (function is tested through a higher-level test)
- No coverage

### 4. Identify Missing Coverage

Priority order for new tests:
1. **Financial document creation/update** (invoices, receipts, payments, notes) — highest impact
2. **Authorization** — security-critical
3. **GL transaction generation** — correctness-critical for accounting
4. **Index queries** — user-facing search functionality
5. **LiveView form/index** — UI functionality
6. **Edge cases** — empty details, zero amounts, boundary dates

### 5. Report Format

For each context, report:

```
## <Context Name>
- Total public functions: N
- Functions with tests: N
- Functions without tests: N
- Test file: <path>
- Fixture file: <path>

### Missing Tests:
- [ ] `function_name/arity` — description of what should be tested
- [ ] `function_name/arity` — description of what should be tested

### Existing Tests That Could Be Enhanced:
- [ ] `test name` — what additional assertions would strengthen it
```

### 6. Generate Test Stubs

For the highest-priority gaps, generate skeleton test code following the patterns in `agents.md`.

## Known Test Files
| Context | Test File | Fixture File | Test Count |
|---------|-----------|--------------|------------|
| Billing | `test/full_circle/billing_test.exs` | `test/support/fixtures/billing_fixtures.ex` | 24 |
| ReceiveFund | `test/full_circle/receive_fund_test.exs` | `test/support/fixtures/receive_fund_fixtures.ex` | 12 |
| BillPay | `test/full_circle/bill_pay_test.exs` | `test/support/fixtures/bill_pay_fixtures.ex` | 9 |
| DebCre | `test/full_circle/debcre_test.exs` | `test/support/fixtures/debcre_fixtures.ex` | 17 |
| Cheque | `test/full_circle/cheque_test.exs` | `test/support/fixtures/cheque_fixtures.ex` | 10 |
| Accounting | `test/full_circle/accounting_test.exs` | `test/support/fixtures/accounting_fixtures.ex` | ~15 |
| Sys | `test/full_circle/sys_test.exs` | `test/support/fixtures/sys_fixtures.ex` | ~20 |
| UserAccounts | `test/full_circle/user_accounts_test.exs` | `test/support/fixtures/user_accounts_fixtures.ex` | ~25 |
| Authorization | `test/full_circle/authorization_test.exs` | *(none)* | ~3 |

## Contexts Likely Missing Tests
- `HR` (employee, salary types, pay slips, time attendance, advances, salary notes)
- `Product` (goods, packaging, deliveries, orders, loads)
- `Layer` (houses, flocks, harvests, movements)
- `JournalEntry` (journal entries)
- `Reporting` (report queries)
- `EInvMetas` (e-invoice metadata)
- `Seeding` (data seeding)
- `WeightBridge` (weighings)

## Run All Tests
```bash
mise exec -- mix test
```
