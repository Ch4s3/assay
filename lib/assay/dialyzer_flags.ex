defmodule Assay.DialyzerFlags do
  @moduledoc """
  Parses and normalizes Dialyzer command-line flags.

  This module converts raw flag inputs (from config or CLI) into the option tuples
  that `:dialyzer.run/1` expects. It validates flags, prevents conflicting options,
  and handles PLT path overrides.

  ## Supported Flags

  Common flags like `--statistics`, `--fullpath`, `--no_spec` are supported.
  Flags that conflict with incremental mode (e.g., `--build_plt`, `--incremental`)
  are disallowed.

  See `parse/3` for details on flag parsing and validation.
  """

  @type source :: :config | :cli
  @type parse_result :: %{
          options: keyword(),
          init_plt: binary() | nil,
          output_plt: binary() | nil
        }

  @no_arg_flags %{
    "--statistics" => [timing: true],
    "--resources" => [report_mode: :quiet, timing: :debug],
    "--raw" => [output_format: :raw],
    "--fullpath" => [filename_opt: :fullpath],
    "--no_indentation" => [indent_opt: false],
    "--no_spec" => [use_contracts: false]
  }

  @single_arg_flags [
    "--error_location",
    "--dump_callgraph",
    "--dump_full_dependencies_graph",
    "--metrics_file",
    "--module_lookup_file",
    "--solver",
    "--output_plt",
    "--plt",
    "--define",
    "--include"
  ]

  @disallowed_flags [
    "--add_to_plt",
    "--build_plt",
    "--remove_from_plt",
    "--check_plt",
    "--no_check_plt",
    "--incremental",
    "--raw_output",
    "--shell",
    "--gui",
    "-c",
    "-r",
    "--get_warnings",
    "--src",
    "-pa"
  ]

  @doc """
  Normalizes config or CLI provided Dialyzer flag inputs into the dial_option
  tuples that `:dialyzer.run/1` expects. Returns the derived options as well as
  a PLT override path (if any).
  """
  @spec parse(term(), source(), binary()) :: parse_result
  def parse(raw_flags, source, project_root) do
    entries = raw_flags |> List.wrap() |> Enum.flat_map(&expand_entry/1)

    {result, excluded_warnings} =
      Enum.reduce(entries, {%{options: [], init_plt: nil, output_plt: nil}, []}, fn entry, acc ->
        process_entry(entry, acc, source, project_root)
      end)

    apply_excluded_warnings(result, excluded_warnings)
  end

  defp process_entry({:option, key, value, original}, {acc, excluded}, _source, _root) do
    ensure_allowed_option!(key, original)
    new_acc = %{acc | options: acc.options ++ [{key, value}]}
    {new_acc, excluded}
  end

  defp process_entry({:flag, flag, arg, original}, {acc, excluded}, source, root) do
    ensure_allowed_flag!(flag, original)
    {updates, override_map} = interpret_flag(flag, arg, source, root, original)
    {new_excluded, new_updates} = split_excluded_warnings(updates)
    excluded_atoms = Enum.map(new_excluded, fn {:exclude_warning, atom} -> atom end)

    new_acc = update_acc_with_flag(acc, new_updates, override_map)
    {new_acc, excluded ++ excluded_atoms}
  end

  defp split_excluded_warnings(updates) do
    Enum.split_with(updates, fn
      {:exclude_warning, _} -> true
      _ -> false
    end)
  end

  defp update_acc_with_flag(acc, updates, override_map) do
    options = acc.options ++ updates
    init_plt = Map.get(override_map, :init_plt, acc.init_plt)
    output_plt = Map.get(override_map, :output_plt, acc.output_plt)
    %{acc | options: options, init_plt: init_plt, output_plt: output_plt}
  end

  defp apply_excluded_warnings(result, []) do
    result
  end

  defp apply_excluded_warnings(result, excluded_warnings) do
    {warnings_opts, other_opts} = Enum.split_with(result.options, fn {k, _} -> k == :warnings end)
    current_warnings = Enum.flat_map(warnings_opts, fn {_, v} -> List.wrap(v) end)
    filtered_warnings = Enum.reject(current_warnings, &(&1 in excluded_warnings))
    new_warnings_opt = if filtered_warnings != [], do: [{:warnings, filtered_warnings}], else: []
    %{result | options: other_opts ++ new_warnings_opt}
  end

  defp expand_entry(entry) when is_binary(entry) do
    entry
    |> OptionParser.split()
    |> from_token_stream(entry)
  end

  defp expand_entry(entry) when is_list(entry) do
    cond do
      entry == [] ->
        []

      Keyword.keyword?(entry) ->
        Enum.flat_map(entry, fn {k, v} -> expand_entry({k, v}) end)

      Enum.all?(entry, &is_integer/1) ->
        entry |> List.to_string() |> expand_entry()

      true ->
        Enum.flat_map(entry, &expand_entry/1)
    end
  end

  defp expand_entry(entry) when is_atom(entry) do
    atom_str = Atom.to_string(entry)

    if String.starts_with?(atom_str, "no_") do
      # Convert :no_improper_lists to exclude :improper_lists from warnings
      # We'll handle this specially in the parse function
      [{:flag, "-W" <> atom_str, nil, entry}]
    else
      expand_entry(Atom.to_string(entry))
    end
  end

  defp expand_entry({flag, value}) when is_atom(flag) do
    [{:option, flag, value, {flag, value}}]
  end

  defp expand_entry({flag, value}) when is_binary(flag) do
    [{:flag, flag, value, {flag, value}}]
  end

  defp expand_entry(other) do
    [{:flag, to_string(other), nil, other}]
  end

  defp from_token_stream(tokens, original),
    do: from_token_stream(tokens, original, [], nil)

  defp from_token_stream([], _original, acc, nil), do: Enum.reverse(acc)

  defp from_token_stream([], original, _acc, waiting_flag) do
    raise Mix.Error, "dialyzer flag #{original} is missing a value for #{waiting_flag}"
  end

  defp from_token_stream(["--" | rest], original, acc, _waiting),
    do: from_token_stream(rest, original, acc, nil)

  defp from_token_stream([token | rest], original, acc, nil) do
    case interpret_token(token) do
      {:no_arg, flag} ->
        entry = {:flag, flag, nil, token}
        from_token_stream(rest, original, [entry | acc], nil)

      {:needs_arg, flag, inline} when is_binary(inline) ->
        entry = {:flag, flag, inline, token}
        from_token_stream(rest, original, [entry | acc], nil)

      {:needs_arg, flag, nil} ->
        from_token_stream(rest, original, acc, flag)
    end
  end

  defp from_token_stream([token | rest], original, acc, waiting_flag) do
    entry = {:flag, waiting_flag, token, {waiting_flag, token}}
    from_token_stream(rest, original, [entry | acc], nil)
  end

  defp interpret_token(token) do
    cond do
      String.starts_with?(token, "-W") -> {:no_arg, token}
      String.starts_with?(token, "-D") -> interpret_define_token(token)
      String.starts_with?(token, "-I") -> interpret_include_token(token)
      true -> interpret_long_flag(token)
    end
  end

  defp interpret_define_token("-D"), do: {:needs_arg, "-D", nil}

  defp interpret_define_token("-D" <> rest) do
    {:needs_arg, "-D", rest}
  end

  defp interpret_include_token("-I"), do: {:needs_arg, "-I", nil}

  defp interpret_include_token("-I" <> rest) do
    {:needs_arg, "-I", rest}
  end

  defp interpret_long_flag(token) do
    case String.split(token, "=", parts: 2) do
      [flag, value] ->
        if flag in @single_arg_flags do
          {:needs_arg, flag, value}
        else
          {:no_arg, flag}
        end

      [flag] ->
        if flag in @single_arg_flags do
          {:needs_arg, flag, nil}
        else
          {:no_arg, flag}
        end
    end
  end

  defp ensure_allowed_flag!(flag, original) do
    if flag in @disallowed_flags do
      raise Mix.Error,
            "dialyzer flag #{inspect(original)} cannot be used in incremental mode"
    end
  end

  defp ensure_allowed_option!(key, original) do
    unless key in [
             :timing,
             :report_mode,
             :output_format,
             :filename_opt,
             :indent_opt,
             :error_location,
             :callgraph_file,
             :mod_deps_file,
             :metrics_file,
             :module_lookup_file,
             :solvers,
             :include_dirs,
             :defines,
             :warnings,
             :use_contracts
           ] do
      raise Mix.Error, "dialyzer option #{inspect(original)} is not supported"
    end
  end

  defp interpret_flag("--statistics", _arg, _source, _root, _original),
    do: {@no_arg_flags["--statistics"], %{}}

  defp interpret_flag("--resources", _arg, _source, _root, _original),
    do: {@no_arg_flags["--resources"], %{}}

  defp interpret_flag("--raw", _arg, _source, _root, _original),
    do: {@no_arg_flags["--raw"], %{}}

  defp interpret_flag("--fullpath", _arg, _source, _root, _original),
    do: {@no_arg_flags["--fullpath"], %{}}

  defp interpret_flag("--no_indentation", _arg, _source, _root, _original),
    do: {@no_arg_flags["--no_indentation"], %{}}

  defp interpret_flag("--no_spec", _arg, _source, _root, _original),
    do: {@no_arg_flags["--no_spec"], %{}}

  defp interpret_flag("--error_location", arg, _source, _root, original) do
    location =
      case arg do
        "line" -> :line
        "column" -> :column
        _ -> raise Mix.Error, "Invalid value for --error_location: #{inspect(original)}"
      end

    {[error_location: location], %{}}
  end

  defp interpret_flag("--solver", arg, _source, _root, original) do
    solver =
      case String.to_atom(arg) do
        :v1 -> :v1
        :v2 -> :v2
        other -> raise Mix.Error, "Unsupported solver #{inspect(other)} in #{inspect(original)}"
      end

    {[solvers: [solver]], %{}}
  end

  defp interpret_flag("--dump_callgraph", arg, _source, root, _original) do
    {[callgraph_file: expand_path(arg, root)], %{}}
  end

  defp interpret_flag("--dump_full_dependencies_graph", arg, _source, root, _original) do
    {[mod_deps_file: expand_path(arg, root)], %{}}
  end

  defp interpret_flag("--metrics_file", arg, _source, root, _original) do
    {[metrics_file: expand_path(arg, root)], %{}}
  end

  defp interpret_flag("--module_lookup_file", arg, _source, root, _original) do
    {[module_lookup_file: expand_path(arg, root)], %{}}
  end

  defp interpret_flag("--output_plt", arg, _source, root, _original) do
    {[], %{output_plt: expand_path(arg, root)}}
  end

  defp interpret_flag("--plt", arg, _source, root, _original) do
    {[], %{init_plt: expand_path(arg, root)}}
  end

  defp interpret_flag("--define", arg, _source, _root, original),
    do: interpret_flag("-D", arg, nil, nil, original)

  defp interpret_flag("-D", arg, _source, _root, original) do
    {macro, value} = parse_define_value(arg, original)
    {[defines: [{macro, value}]], %{}}
  end

  defp interpret_flag("-I", arg, _source, root, _original) do
    {[include_dirs: [expand_path(arg, root)]], %{}}
  end

  defp interpret_flag("--include", arg, source, root, original),
    do: interpret_flag("-I", arg, source, root, original)

  defp interpret_flag(flag, _arg, _source, _root, original) do
    if String.starts_with?(flag, "-W") do
      warning = String.trim_leading(flag, "-W") |> String.to_atom()
      {[warnings: [warning]], %{}}
    else
      raise Mix.Error, "Unsupported dialyzer flag #{inspect(original || flag)}"
    end
  end

  defp parse_define_value(arg, original) do
    case String.split(arg || "", "=", parts: 2) do
      [macro, value] -> {String.to_atom(macro), parse_erlang_term(value, original)}
      [macro] when macro != "" -> {String.to_atom(macro), true}
      _ -> raise Mix.Error, "Invalid define flag #{inspect(original)}"
    end
  end

  defp parse_erlang_term(value, original) do
    charlist = String.to_charlist(value <> ".")

    with {:ok, tokens, _} <- :erl_scan.string(charlist),
         {:ok, term} <- :erl_parse.parse_term(tokens) do
      term
    else
      _ -> raise Mix.Error, "Unable to parse define value in #{inspect(original)}"
    end
  end

  defp expand_path(path, project_root) do
    path
    |> to_string()
    |> Path.expand(project_root)
    |> to_charlist()
  end
end
