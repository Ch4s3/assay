# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [0.6.1] - 2026-06-05

### Fixed

- Fixed syntax error (missing `end`) in the marcli formatter test that caused
  CI to fail with `TokenMissingError`.

## [0.6.0] - 2026-06-05

### Added

- `--format markdown` output format renders Dialyzer warnings as a Markdown
  document, suitable for pasting into issues, PRs, or documentation.
- `--format marcli` output format renders warnings with rich terminal styling
  via the optional [`marcli`](https://hex.pm/packages/marcli) dependency
  (add `{:marcli, "~> 0.3"}` to your project deps to enable).

### Fixed

- Formatter no longer crashes when Dialyzer reports a warning at a line number
  beyond the end of the source file (can occur with macro-generated code,
  protocol implementations, or stale PLT data). Affected both `--format elixir`
  and `--format github` modes.

### Dependencies

- Bumped `erlex` 0.2.8 → 0.2.9 (removes compile-time shift/reduce warnings).
- Bumped `ex_doc` 0.39.3 → 0.40.3.
- Bumped `igniter` 0.7.0 → 0.8.1.
- Bumped `credo` 1.7.18 → 1.7.19 (Elixir 1.20 compatibility).

## [0.5.2] - 2026-02-27

### Fixed

- Made `erlex` a required (non-optional) dependency so that Erlang-to-Elixir
  type conversion works in consuming projects. Previously erlex was optional,
  meaning projects using assay would see raw Erlang notation (e.g.
  `'Elixir.String':t()`) in Success typing and Diff sections unless they
  explicitly added erlex to their own deps.

- Code snippet line numbers now render inside the `│` border with a single
  gutter (e.g. `│ 44  code` instead of `44 │ code`).

## [0.5.1] - 2026-02-26

### Fixed

- GitHub annotations now display the rich formatted body (code snippets, diffs,
  suggestions) instead of the raw Dialyzer message. The formatted body is encoded
  in the `::warning` message parameter so GitHub renders it in the annotation popup.

## [0.5.0] - 2026-02-26

### Improved

- `--format github` now emits a rich elixir-style text body (code snippets,
  context lines) after the `::warning` annotation line, making CI output
  more readable without requiring a separate `--format elixir` pass.

### Fixed

- Umbrella project path resolution: Dialyzer reports paths relative to each
  umbrella app (e.g. `lib/api/admin/chat_context.ex`), which failed to resolve
  when expanded against the project root. Assay now searches `Mix.Project.apps_paths()`
  to find the correct file under umbrella app directories.

## [0.4.0] - 2026-02-24

### Added

- `--no-compile` flag for `mix assay` to skip compilation before running
  Dialyzer. Useful in CI pipelines where the project is already compiled.
  Follows the convention used by `mix test`, `mix credo`, and Dialyxir.
- Clear error messages when `--no-compile` is used with long-running modes
  (`mix assay.watch`, `mix assay.daemon`, `mix assay.mcp`) that require
  recompilation on each analysis cycle.

## [0.3.0] - 2026-01-07

### Fixed

- Several bug and documentation fixes.

## [0.2.0] - 2026-01-07

### Added

- JSON-RPC daemon (`mix assay.daemon`) for programmatic access.
- MCP server (`mix assay.mcp`) for editor/LSP/agent integrations.
- Igniter-powered installer (`mix assay.install`).
- Watch mode (`mix assay.watch`) with debounced re-analysis.
- Multiple output formats: `text`, `elixir`, `github`, `sarif`, `json`, `llm`.
- `dialyzer_ignore.exs` filtering.
- Umbrella project support.
- CI workflow generation (GitHub Actions, GitLab CI).

## [0.1.0] - 2026-01-06

### Added

- Initial release with incremental Dialyzer support.
- Basic CLI via `mix assay`.

[0.6.1]: https://github.com/Ch4s3/assay/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/Ch4s3/assay/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/Ch4s3/assay/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/Ch4s3/assay/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/Ch4s3/assay/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Ch4s3/assay/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Ch4s3/assay/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Ch4s3/assay/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Ch4s3/assay/releases/tag/v0.1.0
