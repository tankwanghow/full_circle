Run tests for the specified target: $ARGUMENTS

## Usage Examples
- `/run-tests` — run all tests
- `/run-tests billing` — run billing context tests
- `/run-tests test/full_circle/billing_test.exs:42` — run specific test at line

## Instructions

1. Determine test scope from arguments:
   - No args: `mise exec -- mix test`
   - Context name (e.g., "billing"): `mise exec -- mix test test/full_circle/billing_test.exs`
   - File path: `mise exec -- mix test <path>`
   - File:line: `mise exec -- mix test <path>:<line>`

2. Run the tests

3. If tests fail:
   - Read the failure output carefully
   - Identify the root cause (assertion failure, compilation error, missing fixture, etc.)
   - Suggest the fix but do NOT auto-fix unless explicitly asked
   - Show the relevant source code around the failure

4. Report summary:
   - Total tests, passed, failed, excluded
   - For failures: test name, expected vs actual, file:line

## Known Test Files
```
test/full_circle/accounting_test.exs
test/full_circle/authorization_test.exs
test/full_circle/billing_test.exs
test/full_circle/bill_pay_test.exs
test/full_circle/cheque_test.exs
test/full_circle/debcre_test.exs
test/full_circle/receive_fund_test.exs
test/full_circle/sys_test.exs
test/full_circle/user_accounts_test.exs
test/full_circle_web/live/account_live_test.exs
test/full_circle_web/live/company_live_test.exs
test/full_circle_web/live/user_*_test.exs
```

## Note
- Expect `missing :database key` errors for QueryRepo — this is harmless noise
- Use `mise exec --` prefix for all mix commands
