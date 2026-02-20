Refactor the context module to reduce duplication: $ARGUMENTS

Provide the context module path (e.g., `lib/full_circle/hr.ex`).

## Refactoring Checklist

Follow the patterns established in previous refactorings (billing, receive_fund, debcre, bill_pay, cheque contexts).

### 1. Read and Understand
- Read the entire context module
- Read all associated schema files
- Read existing tests
- Identify duplicated patterns

### 2. Common Extractions

#### `make_changeset/5` - Admin role check
Look for inline `if user_role == "admin"` blocks and extract:
```elixir
defp make_changeset(module, struct, attrs, com, user) do
  if user_role_in_company(user.id, com.id) == "admin" do
    StdInterface.changeset(module, struct, attrs, com, :admin_changeset)
  else
    StdInterface.changeset(module, struct, attrs, com)
  end
end
```

#### `detail_query/1` - Parameterized detail loading
If multiple functions load details with similar join patterns, extract:
```elixir
defp detail_query(detail_module) do
  from dtl in detail_module,
    join: good in Good, on: good.id == dtl.good_id,
    join: ac in Account, on: dtl.account_id == ac.id,
    # ... common joins ...
    order_by: dtl._persistent_id,
    select: dtl,
    select_merge: %{good_name: good.name, account_name: ac.name, ...}
end
```

#### `apply_simple_filters/4` or `apply_index_filters/6` - Shared filter chains
If index queries have similar filter patterns, extract with keyword opts:
```elixir
defp apply_simple_filters(qry, terms, date_from, opts) do
  search_fields = Keyword.fetch!(opts, :search_fields)
  date_field = Keyword.fetch!(opts, :date_field)
  # Apply search, date filter, etc.
end
```

#### `update_doc_multi/8` - Shared update pipeline
If multiple document updates follow the same pattern (update + delete transactions + log + create transactions):
```elixir
defp update_doc_multi(multi, step_name, schema, doc, doc_no, attrs, com, user, txn_opts) do
  multi
  |> Multi.update(step_name, fn _ -> make_changeset(schema, doc, attrs, com, user) end)
  |> Multi.delete_all(:delete_transaction, ...)
  |> Sys.insert_log_for(step_name, attrs, com, user)
  |> create_doc_transactions(step_name, com, user, txn_opts)
end
```

#### `@txn_opts` - Declarative sign conventions
Replace inline sign logic with module attribute keyword lists:
```elixir
@invoice_txn_opts [
  doc_type: "Invoice",
  control_account: "Account Receivables",
  negate_line: true,
  negate_header: false
]
```

#### `Multi.insert_all` with `build_*` helpers
Replace `Multi.run` + `Repo.insert!` loops with:
```elixir
multi
|> Multi.insert_all(:create_transactions, Transaction, fn %{^name => doc} ->
  build_transactions(doc, com, opts)
end)
```

#### `matched_amount/2` - Parameterized by doc_type
If similar amount calculation functions exist for different doc types, merge with a doc_type parameter.

### 3. Testing Strategy
- **CRITICAL**: Run existing tests BEFORE refactoring to establish baseline
- Run tests AFTER each extraction to verify no regressions
- The goal is behavioral equivalence — no new features, just cleaner code

```bash
mise exec -- mix test test/full_circle/<context>_test.exs
```

### 4. Post-Refactoring Cleanup
- Remove duplicate `alias` statements
- Remove dead code
- Ensure no unused imports

## Previously Completed Refactorings (Reference)
- **Billing**: detail_query/1, make_changeset/5, create_doc_transactions/5, apply_index_filters/6
- **ReceiveFund**: make_changeset/5, detail_query/1, match_trans_query/3, apply_simple_filters/4, update_doc_multi/8, Multi.insert_all with build_* helpers
- **DebCre**: detail_query/1, match_trans_query/3, matched_amount/2, apply_simple_filters/4, @txn_opts, create_note_transactions/5, apply_sign/2
- **BillPay**: make_changeset/5, apply_simple_filters/4, Multi.insert_all with build_* helpers
- **Cheque**: apply_simple_filters/4, Multi.insert_all with build_* helpers
