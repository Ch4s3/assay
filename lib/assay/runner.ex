defmodule Assay.Runner do
  @moduledoc """
  Executes incremental Dialyzer runs directly via `:dialyzer.run/1`.
  """

  alias Assay.{Config, Formatter, Ignore}

  @type run_result :: :ok | :warnings

  @spec run(Config.t(), keyword()) :: run_result
  def run(%Config{} = config, opts \\ []) do
    quiet? = Keyword.get(opts, :quiet, false)

    unless quiet? do
      Mix.shell().info("""
      Assay (incremental dialyzer)
        apps: #{inspect(config.apps)}
        warning_apps: #{inspect(config.warning_apps)}
        plt: #{config.plt_path}
        ignore_file: #{ignore_description(config)}
      """)
    end

    result = analyze(config, opts)

    explain_ignores? = Keyword.get(opts, :explain_ignores, false)

    unless quiet? do
      if explain_ignores? do
        explain_ignored(result.ignored, result.ignore_path, config.project_root)
      else
        log_ignored(result.ignored, result.ignore_path, config.project_root)
      end
    end

    formats = opts[:formats] || [:text]

    Enum.each(formats, fn format ->
      formatter_opts = [
        project_root: config.project_root,
        pretty_erlang: format == :elixir,
        color?: color_enabled?(format)
      ]

      Formatter.format(result.warnings, format, formatter_opts)
      |> Enum.each(&IO.puts/1)
    end)

    unless quiet? do
      print_summary(result)
    end

    result.status
  end

  @doc """
  Runs incremental Dialyzer and returns structured diagnostics without printing.

  This function is useful when you need programmatic access to Dialyzer results
  without formatted output. It compiles the project, runs Dialyzer, decorates
  warnings with metadata, and applies ignore rules.

  ## Return Value

  Returns a map with:
  * `:status` - `:ok` if no warnings, `:warnings` if warnings found
  * `:warnings` - List of visible (non-ignored) warning entries
  * `:ignored` - List of ignored warning entries
  * `:ignore_path` - Path to the ignore file used, or `nil`
  * `:options` - Dialyzer options that were used

  ## Examples

      # Analyze with default options
      config = Assay.Config.from_mix_project()
      result = Assay.Runner.analyze(config)
      result.status
      # => :ok or :warnings
      length(result.warnings)
      # => number of visible warnings

      # Analyze quietly (no output)
      result = Assay.Runner.analyze(config, quiet: true)
      # Returns same structure but without printing

      # Analyze with specific formats (for structured output)
      result = Assay.Runner.analyze(config, formats: [:json])
      # Then format warnings yourself
      json_warnings = Enum.map(result.warnings, fn warning ->
        Assay.Formatter.format([warning], :json, project_root: config.project_root)
      end)
  """
  @spec analyze(Config.t(), keyword()) ::
          %{
            status: run_result,
            warnings: [Ignore.entry()],
            ignored: [Ignore.entry()],
            ignore_path: binary() | nil,
            options: keyword(),
            timings: map()
          }
  def analyze(%Config{} = config, opts \\ []) do
    timings = %{
      compile_start: System.monotonic_time(),
      compile_end: nil,
      dialyzer_start: nil,
      dialyzer_end: nil,
      total_start: System.monotonic_time()
    }

    Mix.Task.run("compile")
    compile_end = System.monotonic_time()
    timings = %{timings | compile_end: compile_end}

    File.mkdir_p!(config.cache_dir)

    options = dialyzer_options(config)

    maybe_print_config(opts, config, options)

    dialyzer_start = System.monotonic_time()
    warnings = run_dialyzer(options)
    dialyzer_end = System.monotonic_time()
    timings = %{timings | dialyzer_start: dialyzer_start, dialyzer_end: dialyzer_end}

    entries = Ignore.decorate(warnings, config.project_root)
    explain? = Keyword.get(opts, :explain_ignores, false)

    {visible, ignored, ignore_path} =
      Ignore.filter(entries, config.ignore_file, explain?: explain?)

    status = if visible == [], do: :ok, else: :warnings

    total_end = System.monotonic_time()
    timings = Map.put(timings, :total_end, total_end)

    %{
      status: status,
      warnings: visible,
      ignored: ignored,
      ignore_path: ignore_path,
      options: options,
      timings: timings
    }
  rescue
    error ->
      reraise error, __STACKTRACE__
  end

  @doc false
  @spec dialyzer_options(Config.t()) :: keyword()
  def dialyzer_options(%Config{} = config) do
    init_plt = config.dialyzer_init_plt || config.plt_path
    output_plt = config.dialyzer_output_plt || config.plt_path

    plt_chars = String.to_charlist(init_plt)
    output_chars = String.to_charlist(output_plt)

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

    opts_with_warnings =
      case config.warnings do
        [] -> base_opts
        warnings -> base_opts ++ [{:warnings, warnings}]
      end

    opts_with_warnings ++ config.dialyzer_flag_options
  end

  defp charlist_paths(config, apps) do
    apps
    |> Enum.map(&format_app(&1, config))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.to_charlist/1)
  end

  defp run_dialyzer(opts) do
    dialyzer_runner().run(opts)
  catch
    {:dialyzer_error, msg} ->
      raise Mix.Error, IO.iodata_to_binary(msg)
  end

  defp format_app(app, config) when is_atom(app) do
    # Try :code.lib_dir first (works for loaded apps and OTP apps)
    case :code.lib_dir(app) do
      {:error, _} ->
        format_app_from_dependency_or_project(app, config)

      path ->
        format_app_from_lib_dir(path, app, config)
    end
  end

  defp format_app(path, config) when is_binary(path) do
    expand_path(path, config.project_root)
  end

  defp format_app(path, config) when is_list(path) do
    path
    |> IO.chardata_to_string()
    |> format_app(config)
  end

  defp format_app(other, _config) do
    raise Mix.Error, "Invalid app identifier: #{inspect(other)}"
  end

  defp format_app_from_dependency_or_project(app, config) do
    case dependency_app_path(app, config) do
      {:ok, path} -> path
      :error -> project_app_path_or_skip(app, config)
    end
  end

  defp format_app_from_lib_dir(path, app, config) do
    ebin_path = Path.join(IO.chardata_to_string(path), "ebin")

    if File.dir?(ebin_path) do
      ebin_path
    else
      format_app_fallback(app, config)
    end
  end

  defp format_app_fallback(app, config) do
    case dependency_app_path(app, config) do
      {:ok, dep_path} ->
        dep_path

      :error ->
        format_app_from_build_path(app, config)
    end
  end

  defp format_app_from_build_path(app, config) do
    build_path = Path.join([config.build_lib_path, Atom.to_string(app), "ebin"])

    if File.dir?(build_path) do
      build_path
    else
      project_app_path_or_skip(app, config)
    end
  end

  defp color_enabled?(:elixir) do
    case System.get_env("MIX_ANSI_ENABLED") do
      "false" -> false
      _ -> true
    end
  end

  defp color_enabled?(_), do: false

  defp dependency_app_path(app, config) do
    # First, try the build_lib_path (where Mix compiles dependencies)
    build_ebin = Path.join([config.build_lib_path, Atom.to_string(app), "ebin"])

    if File.dir?(build_ebin) do
      {:ok, build_ebin}
    else
      dependency_app_path_from_mix_dep(app, config)
    end
  rescue
    _ -> :error
  end

  defp dependency_app_path_from_mix_dep(app, config) do
    deps = Mix.Dep.cached()
    dep = Enum.find(deps, &(&1.app == app))

    if dep do
      dependency_app_path_from_dep(dep, app, config)
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp dependency_app_path_from_dep(dep, app, config) do
    build_path = dep.opts[:build]
    ebin_path = if build_path, do: Path.join([build_path, "ebin"]), else: nil

    cond do
      ebin_path && File.dir?(ebin_path) ->
        {:ok, ebin_path}

      dep.path && File.dir?(Path.join([dep.path, "ebin"])) ->
        {:ok, Path.join([dep.path, "ebin"])}

      true ->
        dependency_app_path_standard_deps(app, config)
    end
  end

  defp dependency_app_path_standard_deps(app, config) do
    deps_path = Path.join([config.project_root, "deps", Atom.to_string(app), "ebin"])

    if File.dir?(deps_path) do
      {:ok, deps_path}
    else
      :error
    end
  end

  defp project_app_path_or_skip(app, %Config{build_lib_path: build_lib_path, project_root: root}) do
    candidate =
      [build_lib_path, Atom.to_string(app), "ebin"]
      |> Path.join()
      |> expand_path(root)

    if File.dir?(candidate) do
      candidate
    else
      # Check if it's a dependency - if so, skip it silently
      deps =
        try do
          Mix.Dep.cached()
          |> Enum.map(& &1.app)
        rescue
          _ -> []
        end

      if app in deps do
        # Skip uncompiled dependencies - log a warning but don't fail
        Mix.shell().info(
          "[Assay] Skipping #{app} (ebin not found - dependency may not be compiled)"
        )

        nil
      else
        # For project apps, we should still raise an error
        raise Mix.Error,
              "Assay could not locate the #{app} ebin under #{build_lib_path}; " <>
                "ensure the project is compiled and listed in mix.exs"
      end
    end
  end

  defp expand_path(path, base) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.expand(path, base)
    end
  end

  defp log_ignored([], _path, _root), do: :ok

  defp log_ignored(ignored, path, root) do
    count = length(ignored)

    Mix.shell().info(
      "Ignored #{count} warning#{plural_suffix(count)} via #{relative_display(path, root)}"
    )
  end

  defp explain_ignored([], _path, _root), do: :ok

  defp explain_ignored(ignored, path, root) do
    count = length(ignored)
    relative_path = relative_display(path, root)

    Mix.shell().info("")
    Mix.shell().info("Ignored #{count} warning#{plural_suffix(count)} via #{relative_path}:")
    Mix.shell().info("")

    ignored
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, index} ->
      explain_entry(entry, index, root)
    end)
  end

  defp print_summary(result) do
    skipped = length(result.ignored)
    visible = length(result.warnings)
    unnecessary_skips = calculate_unnecessary_skips(result.ignored)
    timings = result.timings

    compile_time = calculate_compile_time(timings)
    dialyzer_time = calculate_dialyzer_time(timings)
    total_time = calculate_total_time(timings)

    print_summary_stats(visible, skipped, unnecessary_skips)
    print_summary_timing(total_time, compile_time, dialyzer_time)
  end

  defp calculate_unnecessary_skips(ignored) do
    Enum.count(ignored, fn entry ->
      matched_rules = Map.get(entry, :matched_rules, [])

      matched_rules == [] ||
        Enum.all?(matched_rules, fn {_idx, rule} -> is_nil(rule) end)
    end)
  end

  defp calculate_compile_time(timings) do
    case {Map.get(timings, :compile_start), Map.get(timings, :compile_end)} do
      {start, end_time} when is_integer(start) and is_integer(end_time) ->
        System.convert_time_unit(end_time - start, :native, :millisecond)

      _ ->
        nil
    end
  end

  defp calculate_dialyzer_time(timings) do
    case {Map.get(timings, :dialyzer_start), Map.get(timings, :dialyzer_end)} do
      {start, end_time} when is_integer(start) and is_integer(end_time) ->
        System.convert_time_unit(end_time - start, :native, :millisecond)

      _ ->
        nil
    end
  end

  defp calculate_total_time(timings) do
    case {Map.get(timings, :total_start), Map.get(timings, :total_end)} do
      {start, end_time} when is_integer(start) and is_integer(end_time) ->
        System.convert_time_unit(end_time - start, :native, :millisecond)

      _ ->
        nil
    end
  end

  defp print_summary_stats(visible, skipped, unnecessary_skips) do
    Mix.shell().info("")

    skip_text =
      if unnecessary_skips > 0, do: ", Unnecessary Skips: #{unnecessary_skips}", else: ""

    Mix.shell().info("Total errors: #{visible}, Skipped: #{skipped}#{skip_text}")
  end

  defp print_summary_timing(total_time, compile_time, dialyzer_time) do
    case total_time do
      nil ->
        :ok

      _ ->
        time_parts = build_time_parts(compile_time, dialyzer_time)

        if not Enum.empty?(time_parts) do
          Mix.shell().info(Enum.join(time_parts, ", "))
        end

        Mix.shell().info("Total: #{format_duration(total_time)}")
    end
  end

  defp build_time_parts(compile_time, dialyzer_time) do
    parts = []
    parts = add_time_part(parts, compile_time, "Compile")
    parts = add_time_part(parts, dialyzer_time, "Dialyzer")
    parts
  end

  defp add_time_part(parts, time, label) when is_integer(time) do
    parts ++ ["#{label}: #{format_duration(time)}"]
  end

  defp add_time_part(parts, _time, _label), do: parts

  defp format_duration(milliseconds) do
    cond do
      milliseconds < 1000 ->
        "#{milliseconds}ms"

      milliseconds < 60_000 ->
        seconds = div(milliseconds, 1000)
        ms = rem(milliseconds, 1000)

        if ms > 0 do
          "#{seconds}.#{div(ms, 100)}s"
        else
          "#{seconds}s"
        end

      true ->
        total_seconds = div(milliseconds, 1000)
        minutes = div(total_seconds, 60)
        seconds = rem(total_seconds, 60)
        ms = rem(milliseconds, 1000)

        if ms > 0 do
          "#{minutes}m#{seconds}.#{div(ms, 100)}s"
        else
          "#{minutes}m#{seconds}s"
        end
    end
  end

  defp explain_entry(entry, index, root) do
    location = format_location(entry, root)
    message = format_warning_message(entry)
    matched_rules = Map.get(entry, :matched_rules, [])

    Mix.shell().info("#{index}. #{location}")
    Mix.shell().info("   #{message}")

    if matched_rules != [] do
      rule_descriptions =
        Enum.map_join(matched_rules, "\n   ", fn {rule_idx, rule} ->
          format_rule(rule, rule_idx)
        end)

      Mix.shell().info("   Matched by: #{rule_descriptions}")
    else
      Mix.shell().info("   Matched by: (no rules matched - this shouldn't happen)")
    end

    Mix.shell().info("")
  end

  defp format_location(entry, _root) do
    case {entry.relative_path, entry.line} do
      {relative, line} when not is_nil(relative) and not is_nil(line) ->
        "#{relative}:#{line}"

      {relative, _} when not is_nil(relative) ->
        relative

      {nil, line} when not is_nil(line) ->
        "#{entry.path}:#{line}"

      _ ->
        entry.path || "(unknown location)"
    end
  end

  defp format_warning_message(entry) do
    # Try to extract a concise message from the text
    case entry.text do
      text when is_binary(text) ->
        # Take first line or truncate if too long
        text
        |> String.split("\n")
        |> List.first()
        |> String.slice(0, 100)

      _ ->
        "#{entry.code}"
    end
  end

  defp format_rule(rule, rule_idx) when is_binary(rule) do
    # Truncate long strings
    display = if String.length(rule) > 50, do: String.slice(rule, 0, 47) <> "...", else: rule
    "rule ##{rule_idx + 1}: \"#{display}\""
  end

  defp format_rule(%Regex{} = regex, rule_idx) do
    "rule ##{rule_idx + 1}: ~r/#{Regex.source(regex)}/#{format_regex_opts(regex)}"
  end

  defp format_rule(%{} = rule, rule_idx) do
    parts =
      Enum.map_join(rule, ", ", fn {key, value} ->
        format_rule_part(key, value)
      end)

    "rule ##{rule_idx + 1}: %{#{parts}}"
  end

  defp format_rule(rule, rule_idx) do
    "rule ##{rule_idx + 1}: #{inspect(rule)}"
  end

  defp format_rule_part(key, value) when is_binary(value) do
    display = if String.length(value) > 30, do: String.slice(value, 0, 27) <> "...", else: value
    "#{key}: \"#{display}\""
  end

  defp format_rule_part(key, value) when is_atom(value) do
    "#{key}: :#{value}"
  end

  defp format_rule_part(key, value) when is_integer(value) do
    "#{key}: #{value}"
  end

  defp format_rule_part(key, %Regex{} = regex) do
    "#{key}: ~r/#{Regex.source(regex)}/#{format_regex_opts(regex)}"
  end

  defp format_rule_part(key, value) do
    "#{key}: #{inspect(value)}"
  end

  defp format_regex_opts(%Regex{opts: opts}) do
    Enum.map_join(opts, "", fn
      :caseless -> "i"
      :unicode -> "u"
      :utf8 -> "u"
      :multiline -> "m"
      :dotall -> "s"
      :extended -> "x"
      opt -> Atom.to_string(opt)
    end)
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_), do: "s"

  defp relative_display(nil, _root), do: "dialyzer_ignore.exs"

  defp relative_display(path, root) do
    case Path.relative_to(path, root) do
      relative when relative != path -> relative
      _ -> path
    end
  rescue
    _ -> path
  end

  defp ignore_description(%Config{ignore_file: nil}), do: "none"

  defp ignore_description(%Config{ignore_file: path, project_root: root}) do
    description = relative_display(path, root)

    if File.exists?(path) do
      description
    else
      "#{description} (missing)"
    end
  end

  defp maybe_print_config(opts, config, options) do
    if Keyword.get(opts, :print_config, false) do
      config_snapshot = %{
        project_root: config.project_root,
        apps: config.apps,
        warning_apps: config.warning_apps,
        cache_dir: config.cache_dir,
        plt_path: config.plt_path,
        ignore_file: config.ignore_file,
        dialyzer_flags: config.dialyzer_flags,
        dialyzer_init_plt: config.dialyzer_init_plt,
        dialyzer_output_plt: config.dialyzer_output_plt
      }

      printable =
        options
        |> redact_print_config_options()
        |> inspect(limit: :infinity, pretty: true, charlists: :as_lists)

      selector_block =
        build_selector_block(config.app_sources, config.warning_app_sources)

      discovery_block = discovery_summary(config.discovery_info)

      Mix.shell().info("""
      Assay configuration (from mix.exs):
      #{inspect(config_snapshot, pretty: true, limit: :infinity)}#{selector_block}#{discovery_block}
      Effective Dialyzer options:
      #{printable}
      """)
    end
  end

  defp dialyzer_runner do
    Application.get_env(:assay, :dialyzer_runner_module, :dialyzer)
  end

  defp redact_print_config_options(options) do
    Enum.reject(options, fn
      {key, _value} when key in [:plts, :output_plt, :files_rec, :warning_files_rec] ->
        true

      _ ->
        false
    end)
  end

  defp build_selector_block(app_sources, warning_sources) do
    selector_details =
      [
        selector_info("apps selectors", app_sources),
        selector_info("warning_apps selectors", warning_sources)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if selector_details == "" do
      ""
    else
      "\n#{selector_details}\n"
    end
  end

  defp selector_info(_label, []), do: nil

  defp selector_info(label, selectors) do
    entries =
      selectors
      |> Enum.map_join("\n", fn %{selector: selector, apps: apps} ->
        explanation =
          selector
          |> selector_explanation(apps)
          |> case do
            nil -> ""
            text -> "\n      #{text}"
          end

        "    #{selector} => #{inspect(apps)}#{explanation}"
      end)

    "#{label}:\n#{entries}"
  end

  defp selector_explanation(selector, apps) do
    count = length(apps)
    summary = "#{count} app#{plural_suffix(count)}"

    case selector do
      :project ->
        "#{summary} discovered via Mix.Project.apps_paths/0"

      :project_plus_deps ->
        "#{summary} (project apps + dependencies + base OTP libraries)"

      :current ->
        "#{summary} for the current Mix project (:app)"

      :current_plus_deps ->
        "#{summary} (current app + dependencies + base OTP libraries)"

      other when is_binary(other) ->
        "#{summary} resolved from selector #{other}"

      _ ->
        nil
    end
  end

  defp discovery_summary(%{project_apps: proj, dependency_apps: deps, base_apps: base}) do
    sections =
      [
        {"project apps (Mix.Project.apps_paths())", proj},
        {"dependency apps (mix deps)", deps},
        {"base apps (included automatically)", base}
      ]
      |> Enum.map_join("\n", fn {label, apps} -> "  #{label}: #{inspect(apps)}" end)

    "\nDiscovery sources:\n#{sections}\n"
  end

  defp discovery_summary(_), do: ""
end
