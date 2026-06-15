# Repository Guidelines

Engineering conventions for this repo — the single source of truth for code style, structure, testing, and commits.
Human contributors: see `CONTRIBUTING.md` for the fork/branch/PR workflow, which points back here for standards.

When rendering HTML code, render each attribute on a separate line (for cleaner diffs).
When rendering markdown in `.md` files, render each sentence on a separate line (for cleaner diffs).

Practice TDD when possible. Run tests and address warnings.

## Project Structure & Module Organization

The core blockchain sync logic lives under `lib/bitblocks`, while Phoenix controllers, LiveView components, and HTML helpers are inside `lib/bitblocks_web`.
Shared application scaffolding sits in `lib/bitblocks.ex` and `lib/bitblocks_web.ex`.
Client assets (esbuild bundles, Tailwind config) reside in `assets/`, and database migrations live in `priv/repo/migrations`.
Tests mirror the runtime layout in `test/bitblocks` and `test/bitblocks_web`, with helpers in `test/support`.

## Build, Test, and Development Commands

Run `mix setup` after cloning to fetch deps, prepare the database, and install asset toolchains.
Use `mix phx.server` (or `iex -S mix phx.server` for interactive debugging) to start the app on port 4000 (override with `PORT`).
Compile and minify front-end bundles through `mix assets.build` during development and `mix assets.deploy` before releases.
Database resets follow `mix ecto.reset`; quick migrations use `mix ecto.migrate`.

## Coding Style & Naming Conventions

Format Elixir code with `mix format` before committing; the formatter is configured in `.formatter.exs` and enforces two-space indentation and trailing comma conventions.
Name modules with `Bitblocks.*` CamelCase namespaces, and keep file names snake_case (e.g., `bitblocks_sync.ex`).
Favor pattern matching and pipelines over imperative helpers, and localize LiveView assigns via descriptive atoms such as `:block_height`.
Add `@doc` and `@spec` annotations for public functions; keep functions small and focused on a single responsibility.

## Testing Guidelines

Write tests in the mirrored directory structure using ExUnit.
Follow the `*_test.exs` file pattern and describe scenarios with `test "syncs blocks..."`.
Run suites via `mix test` (the alias automatically boots an isolated database).
For coverage spot-checks, `mix test --cover` is available; cover new contexts with both happy-path and failure-mode cases.
Reuse fixtures from `test/support` where possible.

## Commit & Pull Request Guidelines

Keep commit subjects short and imperative (e.g., `add tx cache`), matching the existing Git history, in present tense.
Squash fixups locally before opening a PR.
Pull requests should explain the intent, reference any issue numbers (e.g., "Fix #123: handle timeout errors"), and include screenshots or console snippets for UI- or sync-facing changes.
Note any schema migrations and coordinated deploy steps in the PR description so reviewers can plan rollout timing.

## Environment & Configuration Tips

Set environment variables for Bitcoin node credentials (e.g., `export BITCOIN_NODE_URL=...`) before running mix tasks.
Secrets should stay out of Git; rely on `config/runtime.exs` for runtime environment reads.
For release deployments, ensure `rel/` configs match the target and run `mix assets.deploy` prior to building releases.
