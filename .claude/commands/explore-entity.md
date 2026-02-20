Explore and explain the implementation of an entity or feature: $ARGUMENTS

## Instructions

Provide a comprehensive overview of the specified entity or feature by reading all relevant files.

### 1. Schema Layer
- Read the schema file(s) in `lib/full_circle/<context>/`
- Document all fields, associations, virtual fields
- Explain changeset functions and validations
- Show compute_fields logic

### 2. Context Layer
- Read the context module in `lib/full_circle/`
- Document all public functions with their signatures
- Explain the Ecto.Multi chain (for documents)
- Show GL transaction creation logic (for financial documents)
- Document index query patterns

### 3. Authorization
- Find the `can?` clauses in `lib/full_circle/authorization.ex`
- List which roles can perform each action

### 4. Web Layer
- Read LiveView files in `lib/full_circle_web/live/<feature>/`
- Document the form fields and validations
- Explain the index/search functionality
- Describe print view logic
- List JS hooks used

### 5. Routes
- Find routes in `lib/full_circle_web/router.ex`
- List all URL paths for this entity

### 6. Tests
- Read test file(s) in `test/full_circle/` and `test/full_circle_web/`
- Read fixture files in `test/support/fixtures/`
- Summarize test coverage

### 7. Database
- Find the migration file(s) in `priv/repo/migrations/`
- Document table structure, indexes, constraints

## Output Format

Provide a structured report with:
- Entity overview and purpose
- Data model diagram (text-based)
- API surface (public functions)
- Authorization matrix
- Route map
- Test coverage summary
- Key code patterns used
- Dependencies on other entities
