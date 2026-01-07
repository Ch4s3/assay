defmodule Assay.Ignore do
  @moduledoc """
  Warning decoration and ignore rule filtering.

  This module wraps raw Dialyzer warnings with metadata (file paths, line numbers,
  warning codes) and applies ignore rules from `dialyzer_ignore.exs` files.

  ## Ignore File Format

  The ignore file (`dialyzer_ignore.exs` by default) should return a list of rules.
  Each rule can be:

  * A string - matches if the warning text contains the string
  * A regex - matches if the warning text matches the regex
  * A map with keys:
    * `:file` or `:relative` - file path pattern (string or regex)
    * `:message` - message text pattern (string or regex)
    * `:line` - exact line number (integer)
    * `:code` or `:tag` - warning code atom (e.g., `:warn_failing_call`)

  ## Example

      # dialyzer_ignore.exs
      [
        "Function will never return",  # Simple string match
        ~r/unknown function/,          # Regex match
        %{file: "lib/legacy.ex"},      # Match all warnings in a file
        %{code: :warn_not_called, line: 42}  # Match specific warning
      ]
  """

  @type entry :: %{
          raw: term(),
          text: String.t(),
          match_text: String.t(),
          path: String.t() | nil,
          relative_path: String.t() | nil,
          line: integer() | nil,
          column: integer() | nil,
          code: atom()
        }

  @doc """
  Wraps raw Dialyzer warnings with useful metadata for formatting and ignore
  matching.

  ## Examples

      # Decorate a single warning
      warning = {:warn_not_called, {"/project/lib/foo.ex", {10, 5}}, {:MyApp, :unused, 1}}
      entries = Assay.Ignore.decorate([warning], "/project")
      [entry] = entries
      entry.code
      # => :warn_not_called
      entry.path
      # => "/project/lib/foo.ex"
      entry.relative_path
      # => "lib/foo.ex"
      entry.line
      # => 10
      entry.column
      # => 5
  """
  @spec decorate([term()], binary()) :: [entry()]
  def decorate(warnings, project_root) do
    Enum.map(warnings, &build_entry(&1, project_root))
  end

  @doc """
  Applies ignore rules (if any) and returns `{kept, ignored, file_path}` where
  the `file_path` is the ignore file that was loaded or `nil` when no file was
  used.

  When `explain?: true` is passed in opts, the ignored entries will include
  a `:matched_rules` field containing the list of rules that matched.

  ## Examples

      # Filter with string rule
      entry = %{
        code: :warn_not_called,
        match_text: "Function MyApp.unused/1 is never called",
        path: "/project/lib/foo.ex",
        relative_path: "lib/foo.ex",
        line: 10
      }
      rules = ["never called"]
      # In real usage, rules come from dialyzer_ignore.exs
      # This is a simplified example
      {kept, ignored, _path} = Assay.Ignore.filter([entry], nil)
      # kept is empty, ignored contains the entry (if rules matched)

      # Filter with file pattern
      entry = %{
        code: :warn_failing_call,
        match_text: "Call will fail",
        path: "/project/lib/legacy.ex",
        relative_path: "lib/legacy.ex",
        line: 5
      }
      # With ignore file containing: [%{file: "lib/legacy.ex"}]
      {kept, ignored, path} = Assay.Ignore.filter([entry], "dialyzer_ignore.exs")
      # If ignore file exists and matches, entry is in ignored list
  """
  @spec filter([entry()], binary() | nil, keyword()) :: {[entry()], [entry()], binary() | nil}
  def filter(entries, ignore_file, opts \\ []) do
    explain? = Keyword.get(opts, :explain?, false)

    case load_rules(ignore_file) do
      {:disabled, _} ->
        {entries, [], nil}

      {:missing, _} ->
        {entries, [], nil}

      {:ok, rules, path} ->
        if explain? do
          filter_with_explanation(entries, rules, path)
        else
          {ignored, kept} = Enum.split_with(entries, &ignored?(&1, rules))
          {kept, ignored, path}
        end
    end
  end

  defp filter_with_explanation(entries, rules, path) do
    {ignored, kept} =
      Enum.split_with(entries, fn entry ->
        matched = find_matching_rules(entry, rules)
        matched != []
      end)
      |> then(fn {ignored_entries, kept} ->
        # Add matched_rules to all ignored entries
        ignored =
          Enum.map(ignored_entries, fn entry ->
            matched = find_matching_rules(entry, rules)
            Map.put(entry, :matched_rules, matched)
          end)

        {ignored, kept}
      end)

    {kept, ignored, path}
  end

  defp find_matching_rules(entry, rules) do
    rules
    |> Enum.with_index()
    |> Enum.filter(fn {rule, _idx} -> rule_matches?(rule, entry) end)
    |> Enum.map(fn {rule, idx} -> {idx, rule} end)
  end

  defp load_rules(nil), do: {:disabled, []}

  defp load_rules(path) do
    cond do
      path in [nil, false] ->
        {:disabled, []}

      File.exists?(path) ->
        case Code.eval_file(path) do
          {rules, _binding} when is_list(rules) ->
            {:ok, rules, path}

          {value, _binding} ->
            raise Mix.Error,
                  "dialyzer_ignore.exs must return a list of rules (got: #{inspect(value)})"
        end

      true ->
        {:missing, path}
    end
  rescue
    error ->
      message = "Failed to load #{relative_or_absolute(path)}: #{Exception.message(error)}"
      reraise Mix.Error, [message: message], __STACKTRACE__
  end

  defp relative_or_absolute(path) when is_binary(path) do
    case Path.relative_to_cwd(path) do
      ^path -> path
      relative -> relative
    end
  rescue
    _ -> path
  end

  defp relative_or_absolute(_), do: "dialyzer_ignore.exs"

  defp build_entry(warning, project_root) do
    {code, location, _message} = normalize_warning(warning)
    {file, loc} = normalize_location(location)
    absolute = normalize_file(file, project_root)
    relative = relative_path(absolute, project_root)
    match_text = format_warning_text(warning)
    display_text = relativize_text(match_text, project_root)

    %{
      raw: warning,
      text: display_text,
      match_text: match_text,
      path: absolute,
      relative_path: relative,
      line: extract_line(loc),
      column: extract_column(loc),
      code: code
    }
  end

  defp normalize_warning({code, location, message}) do
    {extract_code(code), location, message}
  end

  defp normalize_warning({code, location}) do
    {extract_code(code), location, nil}
  end

  defp normalize_location({file, location}), do: {file, location}
  defp normalize_location({file, location, _meta}), do: {file, location}
  defp normalize_location(_), do: {nil, nil}

  defp normalize_file(nil, _root), do: nil

  defp normalize_file(file, root) do
    file
    |> maybe_to_string()
    |> absolute_path(root)
  end

  defp absolute_path(nil, _root), do: nil

  defp absolute_path(path, root) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.expand(path, root)
    end
  rescue
    _ -> path
  end

  defp relative_path(nil, _root), do: nil

  defp relative_path(path, root) do
    Path.relative_to(path, root)
  rescue
    _ -> path
  end

  defp format_warning_text(warning) do
    warning
    |> dialyzer_module().format_warning(filename_opt: :fullpath)
    |> IO.iodata_to_binary()
  end

  defp relativize_text(text, project_root) do
    prefix = project_root |> Path.expand() |> Kernel.<>("/")
    String.replace(text, prefix, "")
  end

  defp extract_line({line, _col}) when is_integer(line), do: line
  defp extract_line({line, _col, _info}) when is_integer(line), do: line
  defp extract_line(line) when is_integer(line), do: line
  defp extract_line(_), do: nil

  defp extract_column({_line, column}) when is_integer(column), do: column
  defp extract_column({_line, column, _info}) when is_integer(column), do: column
  defp extract_column(_), do: nil

  defp ignored?(entry, rules) do
    Enum.any?(rules, &rule_matches?(&1, entry))
  end

  defp rule_matches?(rule, entry) when is_binary(rule) do
    String.contains?(entry.match_text, rule)
  end

  defp rule_matches?(rule, entry) when is_list(rule) do
    rule_matches?(List.to_string(rule), entry)
  end

  defp rule_matches?(%Regex{} = regex, entry) do
    Regex.match?(regex, entry.match_text)
  end

  defp rule_matches?(%{} = rule, entry) do
    Enum.all?(rule, fn
      {:file, pattern} ->
        match_value(entry.path, pattern) or match_value(entry.relative_path, pattern)

      {:relative, pattern} ->
        match_value(entry.relative_path, pattern)

      {:message, pattern} ->
        match_value(entry.match_text, pattern)

      {:line, line} when is_integer(line) ->
        entry.line == line

      {:code, code} ->
        match_code(entry.code, code)

      {:tag, tag} ->
        match_code(entry.code, tag)

      _ ->
        false
    end)
  end

  defp rule_matches?(_rule, _entry), do: false

  defp match_value(nil, _pattern), do: false

  defp match_value(value, pattern) when is_binary(pattern) do
    String.contains?(value, pattern)
  end

  defp match_value(value, pattern) when is_list(pattern) do
    match_value(value, List.to_string(pattern))
  end

  defp match_value(value, %Regex{} = regex) do
    Regex.match?(regex, value)
  end

  defp match_value(_value, _pattern), do: false

  defp match_code(entry_code, pattern) when is_atom(pattern), do: entry_code == pattern

  defp match_code(entry_code, pattern) when is_binary(pattern) do
    Atom.to_string(entry_code) == pattern
  end

  defp match_code(entry_code, pattern) when is_list(pattern) do
    match_code(entry_code, List.to_string(pattern))
  end

  defp match_code(_entry_code, _pattern), do: false

  defp extract_code({code, _meta}) when is_atom(code), do: code
  defp extract_code(code) when is_atom(code), do: code
  defp extract_code(_), do: :unknown

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value) when is_binary(value), do: value
  defp maybe_to_string(value) when is_list(value), do: List.to_string(value)
  defp maybe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_to_string(_), do: nil

  defp dialyzer_module do
    Application.get_env(:assay, :dialyzer_module, :dialyzer)
  end
end
