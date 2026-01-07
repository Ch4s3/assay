# Assay

[![Hex.pm](https://img.shields.io/hexpm/v/assay.svg)](https://hex.pm/packages/assay)
[![HexDocs](https://img.shields.io/badge/hexdocs-documentation-B1A5EE)](https://hexdocs.pm/assay)
[![GitHub Actions](https://github.com/Ch4s3/assay/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Ch4s3/assay/actions)

Incremental Dialyzer for modern Elixir tooling. Assay reads Dialyzer settings
directly from your host app's `mix.exs`, runs the incremental engine, filters
warnings via `dialyzer_ignore.exs`, and emits multiple output formats suited
for humans, CI, editors, and LLM-driven tools.

## Features

* Incremental Dialyzer runs via `mix assay`
* Watch mode (`mix assay.watch`) with debounced re-analysis
* JSON/CLI formatters (`text`, `github`, `sarif`, `lsp`, `ndjson`, `llm`)
* `dialyzer_ignore.exs` filtering with per-warning decorations
* Igniter-powered installer (`mix assay.install`) that configures apps/
  warning_apps in the host project
* JSON-RPC daemon (`mix assay.daemon`) plus an MCP server (`mix assay.mcp`)
  for editor/LSP/agent integrations

## Installation

### Using Igniter (Recommended)

The easiest way to install Assay is using the Igniter-powered installer. First, add both Assay and Igniter to your dependencies:

```elixir
def deps do
  [
    {:assay, "~> 0.3", runtime: false, only: [:dev, :test]},
    {:igniter, "~> 0.6", optional: false}
  ]
end
```

**Important**: Igniter must be in your `mix.exs` dependencies (not optional) for the installer to work.

Then run the installer:

```bash
mix deps.get
mix assay.install --yes
```

The installer will:
- Detect project and dependency apps
- Configure `apps` and `warning_apps` in your `mix.exs`
- Create a `.gitignore` entry for `_build/assay`
- Create a `dialyzer_ignore.exs` file
- Optionally generate CI workflow files (GitHub Actions or GitLab CI)

### Manual Installation

If you prefer not to use Igniter, you can configure Assay manually:

1. Add Assay to your dependencies:

```elixir
def deps do
  [
    {:assay, "~> 0.3", runtime: false, only: [:dev, :test]}
  ]
end
```

2. Add configuration to your `mix.exs`:

```elixir
def project do
  [
    # ... other config ...
    assay: [
      dialyzer: [
        apps: :project_plus_deps,  # or explicit list
        warning_apps: :project      # or explicit list
      ]
    ]
  ]
end
```

3. Create a `dialyzer_ignore.exs` file (optional):

```elixir
# dialyzer_ignore.exs
[]
```

4. Add `_build/assay` to your `.gitignore` (optional but recommended).

## Configuration

### Symbolic Selectors

Assay supports symbolic selectors for `apps` and `warning_apps`:

- `:project` - All project applications (umbrella: all apps from `Mix.Project.apps_paths()`, single-app: `Mix.Project.config()[:app]`)
- `:project_plus_deps` - Project apps + dependencies + base OTP libraries
- `:current` - Current Mix project app only (useful for umbrella projects)
- `:current_plus_deps` - Current app + dependencies + base OTP libraries

### Example Configuration

```elixir
# In mix.exs
def project do
  [
    app: :my_app,
    assay: [
      dialyzer: [
        # Analyze project apps + dependencies
        apps: :project_plus_deps,
        # Only show warnings for project apps
        warning_apps: :project
      ]
    ]
  ]
end
```

You can also mix symbolic selectors with explicit app names:

```elixir
assay: [
  dialyzer: [
    apps: [:project_plus_deps, :custom_app],
    warning_apps: [:project, :another_app]
  ]
]
```

## Usage

### One-off analysis

```bash
mix assay
mix assay --print-config
mix assay --format github --format sarif
```

Exit codes: `0` (clean), `1` (warnings), `2` (error).

### Watch mode

```bash
mix assay.watch
```

Re-runs incremental Dialyzer on file changes and streams formatted output.

### JSON-RPC daemon

```bash
mix assay.daemon
```

Speaks JSON-RPC over stdio. Supported methods:

* `assay/analyze` – run incremental Dialyzer
* `assay/getStatus`, `assay/getConfig`, `assay/setConfig`
* `assay/shutdown`

### MCP server

```bash
mix assay.mcp
```

Implements the Model Context Protocol (`initialize`, `tools/list`, `tools/call`)
and exposes a single tool, `assay.analyze`, which returns the same structured
diagnostics as the daemon. Requests/responses use the standard MCP/LSP framing:
each JSON payload must be prefixed with `Content-Length: <bytes>\r\n\r\n`.

### Pretty-printing Dialyzer terms

Add [`erlex`](https://hexdocs.pm/erlex) to your host project's deps (e.g.
`{:erlex, "~> 0.2", optional: true}`) and pass `--format elixir` to `mix assay`
to render Dialyzer's Erlang detail blocks as Elixir-looking maps/structs (e.g.
`%Ecto.Changeset{}`) while keeping plain output available when the default
`text` format is used.

## Troubleshooting

### macOS: "Too many open files" error

On macOS, Dialyzer's incremental mode opens many files in parallel, which can exceed
the default open file limit. If you encounter errors related to file limits on larger
projects, increase the limit before running Assay:

```bash
ulimit -n 4096  # or higher for very large projects
mix assay
```

To make this permanent, add it to your shell configuration file (e.g., `~/.zshrc`):

```bash
ulimit -n 4096
```

## Development

* `mix test` – unit tests (including daemon + MCP simulations)
* `mix credo` – linting/style checks
* `mix format` – formatter
* `mix assay.watch` – dogfooding watch mode on the library itself

## Status

Assay currently focuses on incremental Dialyzer runs, watch mode, the Igniter
installer, and daemon/MCP integrations. Future milestones include richer
pass-through Dialyzer flag support, additional output formats, and expanded
editor tooling.
