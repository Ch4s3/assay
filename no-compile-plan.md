# Plan: Add `--no-compile` Flag to Assay

## Problem

Running `mix assay --format github` (or any `mix assay` invocation) always
triggers `Mix.Task.run("compile")` before Dialyzer analysis. There is no way
to skip this step. In CI pipelines where the project is already compiled, or
when iterating quickly on ignore rules, the forced compile is wasted work.

## Where Compilation Happens

There is exactly **one** call site:

```
lib/assay/runner.ex:111    Mix.Task.run("compile")
```

This lives inside `Runner.analyze/2`, which is the single bottleneck for every
entry point:

| Entry point          | File                                  | Path to `analyze/2`                                              |
|----------------------|---------------------------------------|------------------------------------------------------------------|
| `mix assay`          | `lib/mix/tasks/assay.ex:37`           | `Assay.run/1` -> `Runner.run/2` -> `Runner.analyze/2`           |
| `mix assay.watch`    | `lib/mix/tasks/assay/watch.ex:23`     | `Watch.run/1` -> `Assay.run/0` -> `Runner.run/2` -> `analyze/2` |
| `mix assay.daemon`   | `lib/mix/tasks/assay.daemon.ex:28`    | `Daemon.serve/1` -> `Runner.analyze/2` (line 134)               |
| `mix assay.mcp`      | `lib/mix/tasks/assay.mcp.ex:28`       | `MCP.serve/1` -> `Daemon.handle_rpc/2` -> `Runner.analyze/2`    |
| `mix assay.print_config` | `lib/mix/tasks/assay.print_config.ex` | Delegates to `mix assay --print-config`                     |

Because `analyze/2` is the single funnel, the fix only needs to touch that
function (and the layers that pass options into it).

## Execution Flow (Current)

```
CLI args: ["--format", "github"]
      │
      ▼
Mix.Tasks.Assay.run/1           (lib/mix/tasks/assay.ex:37)
  ├─ parse_args/1               (lib/mix/tasks/assay.ex:50)
  │    OptionParser.parse/2     strict opts: print_config, format, apps,
  │                             warning_apps, ignore_file, explain_ignores
  │    ──► opts = [formats: [:github], print_config: false, ...]
  │
  ▼
Assay.run/1                     (lib/assay.ex:21)
  ├─ Config.from_mix_project/1  (lib/assay/config.ex:119)
  │    reads mix.exs :assay -> :dialyzer config
  │    resolves apps, warning_apps, paths, flags
  │    ──► %Assay.Config{}
  │
  ▼
Runner.run/2                    (lib/assay/runner.ex:11)
  ├─ prints banner (apps, plt, ignore file)
  ├─ analyze/2                  (lib/assay/runner.ex:102)
  │    ├─ Mix.Task.run("compile")     ◄── THE COMPILE CALL (line 111)
  │    ├─ File.mkdir_p!(cache_dir)
  │    ├─ dialyzer_options/1          builds :dialyzer.run/1 keyword list
  │    ├─ maybe_print_config/3
  │    ├─ run_dialyzer/1              calls :dialyzer.run(options)
  │    ├─ Ignore.decorate/2
  │    ├─ Ignore.filter/3
  │    └─► %{status, warnings, ignored, ignore_path, options, timings}
  │
  ├─ formats each warning via Formatter.format/3
  ├─ prints summary
  └─► :ok | :warnings
```

## Proposed Change

### 1. Add `--no-compile` to CLI parsing (`lib/mix/tasks/assay.ex`)

Add `no_compile: :boolean` to the strict option list in `parse_args/1` and
propagate it through the opts keyword list.

```elixir
# In parse_args/1, add to OptionParser.parse strict list:
no_compile: :boolean

# In the cli_opts builder:
|> Keyword.put(:no_compile, Keyword.get(opts, :no_compile, false))
```

Update the `@moduledoc` to document the new flag.

### 2. Guard the compile call in `Runner.analyze/2` (`lib/assay/runner.ex`)

Make the `Mix.Task.run("compile")` call conditional on the `:no_compile` opt:

```elixir
def analyze(%Config{} = config, opts \\ []) do
  timings = %{
    compile_start: System.monotonic_time(),
    compile_end: nil,
    dialyzer_start: nil,
    dialyzer_end: nil,
    total_start: System.monotonic_time()
  }

  unless Keyword.get(opts, :no_compile, false) do
    Mix.Task.run("compile")
  end

  compile_end = System.monotonic_time()
  timings = %{timings | compile_end: compile_end}
  # ... rest unchanged
end
```

### 3. Update documentation

- `lib/mix/tasks/assay.ex` `@moduledoc` — add `--no-compile` to the Options
  list and add a note that the project must already be compiled.
- `lib/assay/runner.ex` `@doc` for `analyze/2` — document the `:no_compile`
  option.

### 4. Reject `--no-compile` in watch and MCP tasks

Watch mode and MCP are long-running processes that re-analyze on every
change. Skipping compilation would silently analyze stale bytecode on every
iteration, which is always wrong. These tasks must reject the flag with a
clear error.

Both `mix assay.watch` (`lib/mix/tasks/assay/watch.ex:23`) and
`mix assay.mcp` (`lib/mix/tasks/assay.mcp.ex:28`) currently ignore their
args (`_args` / `_argv`). They need to parse for `--no-compile` and raise
before starting.

```elixir
# lib/mix/tasks/assay/watch.ex
@impl true
def run(args) do
  reject_no_compile!(args)
  Mix.Task.run("app.start")
  Application.ensure_all_started(:file_system)
  watch_module().run()
end

defp reject_no_compile!(args) do
  if "--no-compile" in args do
    Mix.raise("--no-compile is not supported with mix assay.watch (watch mode must compile on each change)")
  end
end
```

```elixir
# lib/mix/tasks/assay.mcp.ex
@impl true
def run(argv) do
  reject_no_compile!(argv)
  Mix.Task.run("app.start")
  mcp_module().serve()
end

defp reject_no_compile!(args) do
  if "--no-compile" in args do
    Mix.raise("--no-compile is not supported with mix assay.mcp (the MCP server must compile on each analysis)")
  end
end
```

### 5. Daemon consideration

The daemon (`mix assay.daemon`) is in the same category as MCP — it is
long-running and re-analyzes on RPC calls. The same guard should be added
to `lib/mix/tasks/assay.daemon.ex`:

```elixir
# lib/mix/tasks/assay.daemon.ex
@impl true
def run(argv) do
  reject_no_compile!(argv)
  Mix.Task.run("app.start")
  daemon_module().serve()
end

defp reject_no_compile!(args) do
  if "--no-compile" in args do
    Mix.raise("--no-compile is not supported with mix assay.daemon (the daemon must compile on each analysis)")
  end
end
```

Note: The daemon's `assay/setConfig` JSON-RPC method should also **not**
accept a `no_compile` override. No changes are needed there since we are not
adding `no_compile` to the daemon's `@allowed_overrides` list
(`lib/assay/daemon.ex:19`).

## Files to Change

| File | Change |
|------|--------|
| `lib/mix/tasks/assay.ex` | Add `no_compile: :boolean` to `OptionParser`, propagate to opts, update `@moduledoc` |
| `lib/assay/runner.ex` | Guard `Mix.Task.run("compile")` with `unless opts[:no_compile]`, update `@doc` on `analyze/2` |
| `lib/mix/tasks/assay/watch.ex` | Parse args, raise if `--no-compile` is present |
| `lib/mix/tasks/assay.mcp.ex` | Parse args, raise if `--no-compile` is present |
| `lib/mix/tasks/assay.daemon.ex` | Parse args, raise if `--no-compile` is present |

Five files, small changes each.

## Testing

1. **Unit test for `Runner.analyze/2`** — verify that when `no_compile: true`
   is passed, `Mix.Task.run("compile")` is not invoked. This can use the
   existing dependency-injection pattern (stub the runner module or check that
   the compile task was not run via `Mix.Task.rerun` tracking).

2. **CLI integration test** — verify that `mix assay --no-compile` parses
   correctly and the option reaches `Runner.analyze/2`.

3. **Negative test** — verify that omitting `--no-compile` still compiles
   (existing behavior preserved).

4. **Rejection tests for watch, MCP, and daemon** — verify that each of
   these tasks raises a `Mix.Error` when `--no-compile` is passed:
   - `Mix.Tasks.Assay.Watch.run(["--no-compile"])` raises with message
     mentioning "not supported with mix assay.watch"
   - `Mix.Tasks.Assay.Mcp.run(["--no-compile"])` raises with message
     mentioning "not supported with mix assay.mcp"
   - `Mix.Tasks.Assay.Daemon.run(["--no-compile"])` raises with message
     mentioning "not supported with mix assay.daemon"

## Risks

- **Stale BEAM files** — If a user passes `--no-compile` but the project is
  not compiled, Dialyzer will either fail (missing ebin) or analyze stale
  bytecode. This is the user's responsibility. The `@moduledoc` should warn
  about this.

- **`Mix.Task.run("compile")` is idempotent** — Within a single Mix
  invocation, `Mix.Task.run/1` is a no-op if the task already ran. So in
  practice the compile step is often fast. The flag is most useful in CI
  where a fresh `mix assay` process is started after a separate `mix compile`
  step.

## Precedent

This pattern is well-established in the Elixir ecosystem:

- `mix test --no-compile`
- `mix dialyzer --no-compile` (Dialyxir)
- `mix credo --no-compile`
- `mix ecto.migrate --no-compile`
