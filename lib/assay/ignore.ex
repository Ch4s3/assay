defmodule Assay.Ignore do
  @moduledoc false

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
  """
  @spec decorate([term()], binary()) :: [entry()]
  def decorate(warnings, project_root) do
    Enum.map(warnings, &build_entry(&1, project_root))
  end

  @doc """
  Applies ignore rules (if any) and returns `{kept, ignored, file_path}` where
  the `file_path` is the ignore file that was loaded or `nil` when no file was
  used.
  """
  @spec filter([entry()], binary() | nil) :: {[entry()], [entry()], binary() | nil}
  def filter(entries, ignore_file) do
    case load_rules(ignore_file) do
      {:disabled, _} ->
        {entries, [], nil}

      {:missing, _} ->
        {entries, [], nil}

      {:ok, rules, path} ->
        {ignored, kept} = Enum.split_with(entries, &ignored?(&1, rules))
        {kept, ignored, path}
    end
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
    :erlang.apply(:dialyzer, :format_warning, [warning, [filename_opt: :fullpath]])
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
end
