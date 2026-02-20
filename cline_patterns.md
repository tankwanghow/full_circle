# Cline Patterns

This file documents efficient tool usage patterns and workflows for Cline in the Full Circle project.

## Tool Chain Examples

### Adding a New Simple Entity (e.g., TaxCode)

1. **Explore existing patterns**: `read_file` on `lib/full_circle/accounting/tax_code.ex` to see schema structure.
2. **Check authorization**: `search_files` with regex `can\?\(user, :create_tax_code` to find existing auth.
3. **Create schema**: `write_to_file` for new schema file, using `use FullCircle.Schema`.
4. **Add to context**: `replace_in_file` in `accounting.ex` to add CRUD functions using `StdInterface`.
5. **Add auth**: `replace_in_file` in `authorization.ex` to add `can?/3` clauses.
6. **Create LiveView**: `write_to_file` for `index.ex`, `form.ex`, etc., copying from similar entities.
7. **Add routes**: `replace_in_file` in `router.ex` under company scope.
8. **Test**: `execute_command` with `mix test` on new test file.

### Modifying a LiveView Form

1. **Find form**: `list_files` on `lib/full_circle_web/live/` to locate relevant folder.
2. **Read structure**: `read_file` on `form.ex` to understand handle_event patterns.
3. **Add field**: `replace_in_file` to add input in template and handle in changeset.
4. **Validate**: `execute_command` with `mix phx.server` to test UI.

### Debugging Authorization Issues

1. **Check roles**: `read_file` on `authorization.ex` for `can?/3` functions.
2. **Find usage**: `search_files` with `can\?\(user, :action` to see where called.
3. **Test roles**: `search_files` in test files for `test_authorise_to`.

## Project-Specific Regex for search_files

- Authorization: `def can\?\(user, :create_.*`
- Schema fields: `field :.*_id, :binary_id`
- LiveView events: `def handle_event\("validate"`
- Test fixtures: `def .*_fixture\(`
- Routes: `live "/companies/:company_id/.*"`

## Task Progress Checklists

### New Entity Checklist
- [ ] Schema created with `use FullCircle.Schema`
- [ ] Changeset functions added
- [ ] Context CRUD via StdInterface
- [ ] Authorization added for all roles
- [ ] LiveView files created (index, form, components)
- [ ] Routes added in router.ex
- [ ] Test file and fixtures created
- [ ] Run `mix test` to verify

### LiveView Modification Checklist
- [ ] Template updated with new inputs
- [ ] handle_event added for validation/save
- [ ] Changeset updated in mount
- [ ] Test added for new functionality
- [ ] UI tested with `mix phx.server`

### Deployment Checklist
- [ ] Code committed to git
- [ ] Tests pass locally
- [ ] Run `./deploy_to_linode/deploy.sh`
- [ ] Check server logs for errors
- [ ] Verify app loads in browser