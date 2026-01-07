# Assay

Incremental Dialyzer for modern Elixir tooling. Assay reads Dialyzer settings
directly from your host app’s `mix.exs`, runs the incremental engine, filters
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

Add Assay as a dev/test dependency (local path while developing, Hex release
once published):

```elixir
def deps do
  [
    {:assay, "~> 0.1", runtime: false, only: [:dev, :test]}
  ]
end
```

From the host project, run:

```bash
mix assay.install --yes
```

This detects project/dep apps and injects:

```elixir
assay: [
  dialyzer: [
    apps: [...],
    warning_apps: [...]
  ]
]
```

## Configuration

### Symbolic Selectors

Assay supports symbolic selectors for `apps` and `warning_apps` to simplify configuration:

#### `:project` or `"project"`
Includes all project applications:
- For umbrella projects: all apps from `Mix.Project.apps_paths()`
- For single-app projects: the app from `Mix.Project.config()[:app]`

#### `:project_plus_deps` or `"project+deps"`
Includes project apps plus all dependencies and base OTP libraries:
- Project apps (as defined by `:project`)
- All dependency apps discovered from `_build/<env>/lib/*/ebin`
- Base OTP libraries (`:logger`, `:kernel`, `:stdlib`, `:elixir`, `:erts`)

#### `:current` or `"current"`
Includes only the current Mix project's app:
- Single app from `Mix.Project.config()[:app]`
- Useful for umbrella projects when you want to analyze only one app

#### `:current_plus_deps` or `"current+deps"`
Includes the current app plus all dependencies and base OTP libraries:
- Current app (as defined by `:current`)
- All dependency apps
- Base OTP libraries

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
