# AGENTS.MD

This document provides guidelines for AI agents working on the Assay codebase. It outlines the project's standards, best practices, and architectural principles to ensure consistent, high-quality contributions.

## Project Philosophy

Assay is built around several core principles that guide all development decisions:

- **Human-Readable Output is Highest Priority** - The human-readable output, especially the Elixir format that translates Dialyzer terms and shows good diffs, is the highest priority. Human comprehensible output is VERY important. When developers see a warning, it should be immediately clear what the problem is, where it is, and ideally how to fix it.

- **LLM and Agentic Coding Tool Compatibility** - Making Assay work well with major LLMs and agentic coding tools is a secondary but important goal. We provide structured formats (JSON, SARIF, etc.) and protocols (MCP, JSON-RPC) for agent consumption, but never at the expense of human readability.

- **Incremental Dialyzer Only** - Assay exclusively uses Dialyzer's incremental mode. We never run classic Dialyzer modes (build PLT, add to PLT, etc.). If incremental mode is unavailable, we fail fast with a clear error message.

- **Transparency in Configuration** - All configuration must be transparent and inspectable. Users should be able to see exactly what options are being passed to Dialyzer via `--print-config`.

- **Human-First Outputs with Excellent Diff Visualization** - Our primary output formats focus on showing clear, actionable warnings with sophisticated diff rendering that makes contract mismatches immediately obvious.

- **Stateful Workflows** - Watch mode and daemon mode are primary use cases. One-shot CLI runs reuse the same engine.

- **Umbrella-Native Support** - Correct, predictable behavior for umbrella projects is required. The system must handle multiple apps correctly.

- **Structured Formats for Secondary Use Cases** - While human-readable output is primary, we also provide structured formats (LLM, JSON, SARIF) for CI, editors, and agent consumption.

## Human-Readable Output (HIGHEST PRIORITY)

Human-readable output is the most important aspect of Assay. When a developer sees a warning, they should understand it immediately without needing to parse complex Erlang terms or hunt through documentation.

### Elixir Format with Rich Diffs

The `:text` and `:elixir` formats are the primary outputs. The `:elixir` format uses the optional `erlex` dependency to pretty-print Erlang terms as Elixir-friendly structures (e.g., `%Ecto.Changeset{}` instead of raw Erlang maps).

Our diff rendering system is sophisticated and handles:

- Contract mismatches with +/- highlighting showing expected vs actual
- Color-coded diffs (red for expected/removed, green for actual/added) when color is enabled
- Balanced delimiters (parentheses, braces) to keep diffs readable
- Inline highlighting of differing segments within lines
- Multiline formatting that preserves structure

When adding new warning types, always prioritize clear, human-readable output with good diffs. Study the existing warning handlers in `lib/assay/formatter/warning/` to understand the patterns.

Key files:
- `lib/assay/formatter/helpers.ex` - Extensive diff rendering logic (Myers algorithm, inline diffs, map entry diffs)
- `lib/assay/formatter/warning.ex` - Warning rendering orchestration
- `lib/assay/formatter/warning/contract_diff.ex` - Example of rich diff rendering for contract mismatches

### Output Quality Standards

All human-readable output should meet these standards:

- **Immediate Comprehensibility** - A developer should understand the warning without reading documentation
- **Code Snippets** - Show the actual code with line numbers and column indicators pointing to the exact location
- **Context** - Include file path, line number, and column when available
- **Erlang to Elixir Translation** - Convert Erlang binaries to Elixir strings, show structs in Elixir syntax
- **Consistent Visual Language** - Use box drawing characters (┌─, │, └─), consistent indentation, and color when appropriate

The text format rendering in `lib/assay/formatter.ex` (lines 193-216) shows how we combine location, code snippets, and formatted details into a cohesive warning display.

### Error Message Inspiration

Human-readable errors should take inspiration from the Elixir compiler, Rust, and Elm. These compilers are renowned for excellent error messages that:

- Provide clear, actionable messages
- Show code snippets with the problematic code highlighted
- Use visual indicators (carets `^`, underlines) pointing to exact locations
- Include contextual information explaining why the error occurred
- Offer suggestions for how to fix the issue
- Maintain consistent formatting and visual language

When designing error messages or warnings, study examples from:

- **Elixir compiler errors** - Clear, helpful, with code context. Notice how they show the file, line, and a snippet of code with a caret pointing to the issue.

- **Rust compiler errors** - Detailed explanations with suggestions. They explain not just what's wrong, but often why it's wrong and what you might have meant.

- **Elm compiler errors** - Friendly, educational tone. They teach you about the language while pointing out issues.

Apply these principles to Dialyzer warning formatting. When a contract mismatch occurs, don't just show the types—show them in context, highlight the differences clearly, and if possible, suggest what might fix it.

### Elixir Term Translation

Dialyzer works with Erlang terms, but our output should feel native to Elixir developers. We convert:

- Erlang binaries (`<<116,105,116,108,101>>`) to Elixir strings (`"title"`)
- Erlang maps to Elixir map syntax
- Complex terms are pretty-printed using `erlex` when available
- Structs are shown in Elixir syntax (e.g., `%Ecto.Changeset{}`)

The term formatting logic in `lib/assay/formatter/helpers.ex` (lines 27-57) handles this translation. When adding new formatting, ensure Erlang terms are presented in an Elixir-friendly way.

## LLM and Agentic Coding Tool Support (SECONDARY GOAL)

While human-readable output is primary, Assay also provides structured formats and protocols for LLM and agentic coding tool consumption. This is a secondary goal that should never compromise human readability.

### Structured Output Formats

Assay provides several structured formats for machine consumption:

- **`llm` format** - JSON optimized for LLM consumption with single-line messages and structured data. See `lib/assay/formatter.ex` lines 78-97 for implementation.

- **`json` format** - Machine-readable JSON objects, one per warning, with full diagnostic information. When printed line-by-line, this effectively serves as newline-delimited JSON (NDJSON) for streaming scenarios.

- **`github` format** - GitHub Actions workflow annotations (`::warning file=...::message`) for CI integration.

- **`sarif` format** - SARIF 2.1.0 standard format for static analysis tools and CI integration.

These formats are secondary to the human-readable formats. When adding new warning types, ensure the human-readable output is excellent first, then ensure structured formats capture the same information.

### MCP (Model Context Protocol) Server

The `mix assay.mcp` command provides an MCP server over stdio for agent integration. It implements the standard MCP protocol:

- `initialize` - Handshake and capability negotiation
- `tools/list` - Lists available tools (currently just `assay.analyze`)
- `tools/call` - Invokes the `assay.analyze` tool

The server uses Content-Length framing for stdio communication (each JSON payload is prefixed with `Content-Length: <bytes>\r\n\r\n`).

See `lib/assay/mcp.ex` for the full implementation. The MCP server wraps the daemon and exposes Assay's analysis capabilities to MCP-compatible clients.

### JSON-RPC Daemon

The `mix assay.daemon` command provides a JSON-RPC daemon over stdio. It supports these methods:

- `assay/analyze` - Triggers an incremental Dialyzer run and returns structured diagnostics
- `assay/getStatus` - Reports daemon status and last run result
- `assay/getConfig` - Returns current configuration (including overrides)
- `assay/setConfig` - Applies configuration overrides (apps, warning apps, etc.)
- `assay/shutdown` - Cleanly stops the daemon

The daemon returns structured diagnostics in JSON format suitable for programmatic consumption. See `lib/assay/daemon.ex` for implementation details.

### Deterministic Outputs

All outputs, whether human-readable or structured, must be:

- **Deterministic** - Same input produces same output
- **Stable** - Output format doesn't change unexpectedly
- **Consistent** - Structured data uses consistent schemas
- **Parseable** - Error messages are machine-parseable when needed

Exit codes are standardized:
- `0` - Clean (no warnings after ignores)
- `1` - Warnings detected
- `2` - Error occurred

### Agent-Friendly Features

Several features support programmatic use:

- **`--print-config`** - Machine-readable configuration output showing exactly what will be passed to Dialyzer
- **Quiet mode** - Suppresses informational output for non-interactive use
- **Programmatic configuration** - Daemon and MCP support runtime configuration overrides
- **Structured error messages** - Errors include structured data for programmatic handling

### Standards for Agent Tools

When adding features that might be consumed by agents or LLMs:

1. **Prioritize human-readable output first** - Make sure the human sees an excellent, clear message
2. **Then provide structured formats** - Ensure JSON/SARIF/etc. formats capture the same information
3. **Document schemas clearly** - Use `@doc` to document output formats and their schemas
4. **Ensure parseability** - Structured outputs should be easy to parse programmatically
5. **Test agent integration** - Include tests that verify structured outputs are correct
6. **Never sacrifice human readability** - If there's a conflict, human readability wins

## Elixir Standards

Assay follows standard Elixir conventions and best practices:

- **Style Guide** - Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- **Formatting** - Always run `mix format` before committing. The formatter configuration is in `.formatter.exs`
- **Pattern Matching** - Prefer pattern matching and guards over conditionals
- **Type Documentation** - Use `@spec` for function type documentation
- **Naming Conventions** - Follow Elixir naming: PascalCase for modules, snake_case for functions and variables
- **Documentation** - Use `@moduledoc` for module documentation and `@doc` for function documentation. All public modules and functions must be documented.
- **Testing Expectations** - Add tests for new behavior and bug fixes. Prefer small, focused tests that cover branches and structured outputs (text/JSON/SARIF/MCP). Run `mix test` and `mix test --cover` when touching warning formatting, daemon/MCP, or watch/runner behavior.
- **Coverage Target** - Overall coverage target is 90%. If coverage drops, treat fixing it as secondary priority after the current task’s core work is complete.

## Self-Evaluation

Assay uses itself to analyze its own codebase. This "dogfooding" ensures the tool works well in real-world scenarios.

The library configuration is in `mix.exs` (lines 37-44):

```elixir
defp assay do
  [
    dialyzer: [
      apps: assay_apps(),
      warning_apps: [:assay]
    ]
  ]
end
```

During development:

- Run `mix assay` to check the codebase for warnings
- Use `mix assay.watch` for continuous feedback as you code
- Fix any warnings that appear—they're real issues in the codebase

## Operational Standards

### Error Handling

- **User-Facing Errors** - Use `Mix.raise/1` for CLI-facing errors that should stop execution with a clear message.
- **Recoverable Failures** - Return tagged tuples or explicit `{:error, reason}` where a caller can decide to continue (e.g., watcher setup, MCP framing).
- **Structured Errors** - When emitting JSON-RPC or MCP errors, include both a code and a concise message, and attach structured data when it adds actionable context.

### Performance and Concurrency

- **Watch/Daemon Responsiveness** - Avoid long synchronous work on the main loop; prefer tasks and debounced scheduling.
- **Determinism** - Ensure output ordering is stable across runs, especially when iterating maps or sets.
- **Resource Discipline** - Avoid spawning unbounded tasks or leaking processes; clean up watchers and tasks on shutdown.

### Compatibility Targets

- **OTP Target** - Assay targets OTP >= 27. Avoid APIs removed in OTP 27 and ensure changes are compatible with this baseline.
- **Elixir Target** - Minimum supported Elixir version is 1.18.

## Dependency Management

Assay minimizes dependencies to reduce maintenance burden and potential security issues.

**Essential dependencies:**
- `file_system` (required) - File watching for watch mode
- `credo` (dev only) - Code linting and style checking
- `ex_doc` (dev only) - Documentation generation

**Optional dependencies:**
- `igniter` (optional) - Used by `mix assay.install` for project setup
- `erlex` (optional) - Used for pretty-printing Erlang terms in `:elixir` format

When considering adding a dependency:

1. Is it absolutely necessary? Can we use OTP/Elixir standard library instead?
2. Is it well-maintained? Check recent commits and issue resolution
3. Does it add significant value? Avoid dependencies for trivial functionality
4. Can it be optional? Mark dependencies as optional when possible

Prefer OTP and Elixir standard library functions over external dependencies whenever possible.

## Testing Standards

Testing is critical for maintaining code quality. Follow these standards:

### Async vs Sync Tests

- **Prefer `async: true`** - Use for tests that don't require shared state or global resources
- **Use `async: false`** - Only when necessary (Mix tasks, daemon, file system operations, Application environment changes)

Most formatter tests use `async: true` because they're pure functions. Mix task tests use `async: false` because they interact with Mix's global state.

### Coverage

- **Target: 90%+ coverage** - Currently at 85.24%, aim to improve
- **Run `mix test --cover`** - Check coverage regularly
- **Focus on edge cases** - Don't just test happy paths; test error conditions, boundary cases, and unusual inputs

### Test Organization

- **Descriptive test names** - Test names should clearly describe what they're testing
- **Test edge cases** - Include tests for error paths, boundary conditions, and unusual scenarios
- **Use test stubs** - `test_helper.exs` provides stubs for dependency injection (e.g., `ConfigStub`, `RunnerStub`)
- **Test agent integration** - Include tests for MCP and daemon scenarios

### Test Patterns

The codebase uses several testing patterns:

- **Dependency injection** - Use Application environment or function parameters to inject test doubles
- **Temporary directories** - Use `@moduletag :tmp_dir` for tests that need file system access
- **Process communication** - Use message passing to test async behavior
- **IO capture** - Use `ExUnit.CaptureIO` for testing output

See `test/assay_watch_test.exs` for examples of complex async testing with file system stubs and process communication.

## Documentation Standards

Documentation should be clear, helpful, and written in plain language.

### Writing Style

- **Plain, natural prose** - Write as if explaining to a colleague
- **Avoid jargon** - Use technical terms when necessary, but explain them
- **Be concise** - Say what needs to be said, no more
- **Use examples** - Show, don't just tell

### Module Documentation

Every public module must have `@moduledoc` that explains:

- What the module does
- When to use it
- Key concepts or patterns it implements
- Examples of common usage

### Function Documentation

Every public function must have `@doc` that includes:

- What the function does
- Parameters and return values
- Examples (preferably as doctests)
- Any important behavior or edge cases

### Doctests

Use doctests when they add value:

```elixir
@doc """
Adds two numbers.

## Examples

    iex> add(2, 3)
    5
"""
```

Doctests are compiled and can be run with `mix test --only doctest`, but they're also valuable documentation.

### Output Format Documentation

When documenting output formats (especially for agent consumption), include:

- Schema descriptions
- Example outputs
- Field descriptions
- Version information if formats evolve

## OTP Dialyzer Incremental Mode

Assay exclusively uses Dialyzer's incremental mode. This is a core architectural decision that must be maintained.

### Direct OTP Usage

Always use `:dialyzer.run/1` directly. Never use CLI wrappers or shell commands. The exact options are constructed in `Assay.Runner.dialyzer_options/1` (see `lib/assay/runner.ex` lines 89-99):

```elixir
base_opts = [
  {:analysis_type, :incremental},
  {:check_plt, false},
  {:from, :byte_code},
  {:get_warnings, true},
  {:report_mode, :quiet},
  {:plts, [plt_chars]},
  {:output_plt, output_chars},
  {:files_rec, charlist_paths(config, config.apps)},
  {:warning_files_rec, charlist_paths(config, config.warning_apps)}
]
```

Key points:

- **`analysis_type: :incremental`** - This is mandatory. Incremental mode is the only mode we support.
- **`check_plt: false`** - Incremental mode manages the PLT automatically
- **`from: :byte_code`** - We analyze compiled BEAM files, not source
- **`files_rec` and `warning_files_rec`** - These specify which apps to analyze and which to report warnings for

### Disallowed Flags

Certain Dialyzer flags are disallowed because they conflict with incremental mode or our design goals. See `lib/assay/dialyzer_flags.ex` lines 33-48:

- `--add_to_plt`, `--build_plt`, `--remove_from_plt` - Classic PLT management (we use incremental PLT)
- `--check_plt`, `--no_check_plt` - PLT checking (incremental mode handles this)
- `--incremental` - Redundant (we always use incremental)
- `--shell`, `--gui` - Interactive modes (we're a CLI/library tool)
- `-c`, `-r`, `--src` - Source file analysis (we use byte code)
- `--get_warnings` - Always enabled (we always want warnings)

If a user tries to use a disallowed flag, we raise a clear error explaining why it's not allowed.

### Staying Close to OTP

When in doubt about how to use Dialyzer, refer to:

- OTP documentation for `:dialyzer` module
- The incremental mode commit: https://github.com/erlang/otp/commit/963c7d5ccecb9ea4940e7112d88534781a413fa6
- Dialyxir's incremental mode PR for UX patterns: https://github.com/jeremyjh/dialyxir/pull/575

Don't abstract away from OTP's model. We map directly to Dialyzer's `--apps` and `--warning_apps` concepts rather than inventing new abstractions.

## Code Quality

Maintain high code quality through tooling and practices:

### Credo

Run `mix credo --strict` before committing. Credo checks for:

- Code clarity and readability
- Potential bugs and code smells
- Style consistency
- Documentation coverage

Address all Credo warnings. If you disagree with a warning, discuss it rather than ignoring it.

### Formatting

Always run `mix format` before committing. The formatter ensures consistent style across the codebase. The formatter configuration is in `.formatter.exs`.

### Code Patterns

- **Pattern matching over conditionals** - Prefer `case`, `cond`, and pattern matching over `if`/`unless`
- **Explicit error handling** - Use `{:ok, result}` / `{:error, reason}` tuples or raise exceptions explicitly. Don't fail silently.
- **Guard clauses** - Use guards to make pattern matching more expressive
- **Pipe operator** - Use `|>` for data transformation pipelines, but don't overuse it

### Error Handling

- **Fail fast** - If something is wrong, fail immediately with a clear error
- **Clear error messages** - Error messages should explain what went wrong and ideally how to fix it
- **Structured errors** - Use `Mix.raise/1` (which raises `Mix.Error`) for user-facing errors with helpful messages

## Architecture Guidelines

The codebase is organized into focused, single-purpose modules:

### Module Organization

- **`Assay`** - Main entry point, lightweight façade
- **`Assay.Config`** - Configuration loading and normalization from `mix.exs`
- **`Assay.Runner`** - Executes Dialyzer runs via `:dialyzer.run/1`
- **`Assay.Formatter`** - Formats warnings into various output formats
- **`Assay.Formatter.Warning`** - Warning-specific rendering logic
- **`Assay.Formatter.Helpers`** - Shared formatting utilities (diffs, term translation)
- **`Assay.Ignore`** - Handles `dialyzer_ignore.exs` filtering
- **`Assay.Watch`** - File watching and debounced re-analysis
- **`Assay.Daemon`** - JSON-RPC daemon for programmatic access
- **`Assay.MCP`** - MCP server wrapper around daemon
- **`Assay.DialyzerFlags`** - Parses and normalizes Dialyzer flags
- **`Mix.Tasks.Assay.*`** - Mix task implementations

### Dependency Injection

Use Application environment for dependency injection to enable testing:

```elixir
config_module = Application.get_env(:assay, :config_module, Config)
runner_module = Application.get_env(:assay, :runner_module, Runner)
```

This pattern allows tests to inject stubs (see `test_helper.exs` for `ConfigStub` and `RunnerStub`).

### Data Structures

- **Structs for configuration** - `Assay.Config` is a struct that holds all configuration
- **Keyword lists for options** - Function options use keyword lists
- **Structs for state** - Stateful modules (Watch, Daemon, MCP) use structs for state

### API Design

When designing APIs:

- **Human consumption first** - Design for human readability, then add structured formats
- **Clear function names** - Function names should clearly indicate what they do
- **Consistent patterns** - Follow existing patterns in the codebase
- **Documentation** - Document all public APIs thoroughly

## Development Workflow

Common tasks and commands:

### Testing

- `mix test` - Run all tests
- `mix test --cover` - Run tests with coverage report
- `mix test test/path/to_test.exs` - Run specific test file
- `mix test test/path/to_test.exs:42` - Run test at line 42

### Code Quality

- `mix credo` - Run Credo linter
- `mix credo --strict` - Run with strict checks (use before committing)
- `mix format` - Format all code
- `mix format --check-formatted` - Check if code is formatted (useful in CI)

### Self-Evaluation

- `mix assay` - Run Assay on the codebase
- `mix assay --print-config` - See effective configuration
- `mix assay.watch` - Watch mode during development (dogfooding)

### Agent Integration Testing

- `mix assay.mcp` - Start MCP server (test with MCP client)
- `mix assay.daemon` - Start JSON-RPC daemon (test with JSON-RPC client)

### Documentation

- `mix docs` - Generate documentation
- Documentation is generated in `doc/` directory

### Coverage

- `mix test --cover` - Generate coverage report
- Coverage HTML is in `cover/` directory
- Target: 90%+ coverage (currently 85.24%)

## Additional Best Practices

### When Adding New Features

1. **Start with human-readable output** - Design the warning/error message first. Make it excellent.
2. **Then add structured formats** - Ensure JSON/SARIF/etc. capture the same information
3. **Write tests** - Include tests for both happy paths and edge cases
4. **Update documentation** - Document new features in `@moduledoc` and `@doc`
5. **Self-evaluate** - Run `mix assay` to ensure the feature works correctly
6. **Check coverage** - Ensure new code is covered by tests

### When Fixing Bugs

1. **Reproduce the bug** - Write a test that demonstrates the bug
2. **Fix the bug** - Make the test pass
3. **Verify self-evaluation** - Run `mix assay` to ensure no regressions
4. **Update documentation** - If behavior changes, update docs

### When Refactoring

1. **Maintain behavior** - Refactoring should not change functionality
2. **Update tests if needed** - Tests might need updates if structure changes
3. **Keep documentation current** - Ensure docs reflect the new structure
4. **Run full test suite** - Ensure nothing broke

### Code Review Checklist

When reviewing code (or preparing code for review):

- [ ] All tests pass (`mix test`)
- [ ] Credo passes (`mix credo --strict`)
- [ ] Code is formatted (`mix format`)
- [ ] Self-evaluation passes (`mix assay`)
- [ ] Coverage is maintained or improved
- [ ] Documentation is updated
- [ ] Human-readable output is clear and helpful
- [ ] Structured formats (if applicable) are correct
- [ ] Error messages are clear and actionable
- [ ] No new dependencies added (or justified if added)

## Conclusion

Assay prioritizes human-readable output that helps developers understand and fix Dialyzer warnings quickly. While we support LLM and agentic coding tools as a secondary goal, human comprehension always comes first.

When in doubt, ask: "Would a developer understand this immediately?" If the answer is no, improve the output. Then, if needed, ensure structured formats capture the same information for programmatic consumption.

Follow Elixir standards, maintain high test coverage, document thoroughly, and stay close to OTP's Dialyzer incremental mode. The codebase should be a pleasure to work with, both for humans and for the tools that help them.
