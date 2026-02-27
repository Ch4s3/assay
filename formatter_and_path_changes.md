# Assay: GitHub Format + Umbrella Path Fix

## Problem

Two issues when using `mix assay --format github` in umbrella projects:

### 1. GitHub format output is minimal

The `--format github` emits a single line per warning:

```
::warning file=lib/api/admin/chat_context.ex,line=24::The @spec for create_ui_message/3 ...
```

The `--format elixir` output is much richer — code snippets, context lines, warning category — but doesn't produce GitHub annotations. You have to choose between readable output and annotations.

### 2. File paths are wrong in umbrella projects

Dialyzer reports paths relative to each umbrella app (e.g. `lib/api/admin/chat_context.ex`). Assay's `absolute_path/2` does `Path.expand(path, project_root)` which produces `/repo/lib/api/admin/chat_context.ex` — a file that doesn't exist. The real file is at `/repo/apps/api/lib/api/admin/chat_context.ex`.

This means:
- GitHub annotations point to non-existent files (no inline warnings on PRs)
- `format_snippet/3` silently fails to read the file, so code context is missing from elixir/text output too

## Changes

### 1. Rich GitHub format (`lib/assay/formatter.ex`)

Change `format(entries, :github, opts)` to emit the `::warning` annotation line followed by the same rich text block that `:elixir` uses.

**Before:**
```elixir
def format(entries, :github, opts) do
  project_root = Keyword.fetch!(opts, :project_root)

  Enum.map(entries, fn entry ->
    path = entry.relative_path || relative_display(entry.path, project_root) || "unknown"
    line = entry.line || 0
    message = entry |> entry_message() |> github_escape()
    "::warning file=#{path},line=#{line}::#{message}"
  end)
end
```

**After:**
```elixir
def format(entries, :github, opts) do
  opts = Keyword.put(opts, :pretty_erlang, true)
  project_root = Keyword.fetch!(opts, :project_root)

  Enum.map(entries, fn entry ->
    path = entry.relative_path || relative_display(entry.path, project_root) || "unknown"
    line = entry.line || 0
    message = entry |> entry_message() |> github_escape()
    annotation = "::warning file=#{path},line=#{line}::#{message}"
    body = format_text_entry(entry, project_root, opts)
    annotation <> "\n" <> body
  end)
end
```

### 2. Umbrella path resolution (`lib/assay/ignore.ex`)

Fix `absolute_path/2` to check umbrella app paths when the expanded path doesn't exist. Uses `Mix.Project.apps_paths/0` which returns the actual app directories regardless of naming convention (handles non-standard `apps_path` config).

**Before:**
```elixir
defp absolute_path(path, root) do
  case Path.type(path) do
    :absolute -> path
    _ -> Path.expand(path, root)
  end
rescue
  _ -> path
end
```

**After:**
```elixir
defp absolute_path(path, root) do
  case Path.type(path) do
    :absolute -> path
    _ ->
      expanded = Path.expand(path, root)
      if File.exists?(expanded) do
        expanded
      else
        case Mix.Project.apps_paths() do
          paths when is_map(paths) ->
            paths
            |> Map.values()
            |> Enum.find_value(fn app_path ->
              candidate = Path.expand(path, Path.join(root, app_path))
              if File.exists?(candidate), do: candidate
            end)
            |> Kernel.||(expanded)
          _ ->
            expanded
        end
      end
  end
rescue
  _ -> path
end
```

## Effects

Once both changes land:

- `--format github` gives readable log output AND inline PR annotations
- Umbrella projects get correct file paths automatically (annotations work, code snippets work)
- No external shell script needed for path rewriting
- Works with any `apps_path` config, not just the default `"apps"`
