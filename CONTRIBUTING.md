# Contributing

Issues and pull requests are welcome.

## Before opening a PR

```bash
terraform fmt -recursive -check
terraform init -backend=false && terraform validate && terraform test
(cd examples/basic && terraform init -backend=false && terraform validate)
(cd examples/with-athena && terraform init -backend=false && terraform validate)
python -m pytest tests -q && ruff check lambda tests && ruff format --check lambda tests
node --test tests/collector.test.js
```

CI runs the same checks on every push and pull request.

## Guidelines

- Privacy first: the collector never reads input values, keystrokes or page
  text, and sends nothing under GPC/DNT. A change that weakens this won't merge.
- Keep the defaults safe and least-privilege; add-ons stay off by default.
- A change to the event schema bumps `v` and documents the migration.
