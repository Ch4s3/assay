defmodule Assay.Formatter.Warning do
  @moduledoc """
  Shared helpers for turning Dialyzer warning payloads into friendly, Elixir-style
  text sections. A handler can take an `entry` (as delivered by the formatter),
  produce a `%Result{headline, details}`, and lean on these utilities for consistent
  indentation, diff highlighting, and term rendering.

  ## Example: using the diff helpers

  ```elixir
  # Given two one-line specs, render a +/- diff with balanced parens and color.
  opts = [color?: true]
  expected = ["([integer()]) :: integer() | nil"]
  actual   = ["(maybe_improper_list()) :: any()"]

  Assay.Formatter.Helpers.diff_lines(expected, actual, opts)
  # => [
  #      IO.ANSI.red()   <> "-  ([integer()]) :: integer() | nil" <>
  #      IO.ANSI.reset(),
  #      IO.ANSI.green() <> "+  (maybe_improper_list()) :: any()" <>
  #      IO.ANSI.reset()
  #    ]
  ```

  ## Example: rendering Erlang terms as Elixir-friendly text

  ```elixir
  Assay.Formatter.Helpers.format_term_lines("%{title => <<116,105,116,108,101>>}")
  # => ["%{:title => \"title\"}"]
  ```

  Handlers that need more control (maps, specs, nested structs) can combine
  `diff_segments/3`, `diff_map_entries/3`, and `format_term_lines/1` to build
  domain-specific sections while preserving the same visual language used by
  other warnings.
  """

  defmodule Result do
    @moduledoc false
    defstruct [:headline, details: []]

    @type t :: %__MODULE__{
            headline: String.t() | nil,
            details: [String.t()]
          }
  end

  alias __MODULE__.Result
  alias Assay.Formatter.Helpers
  alias Assay.Formatter.Warning.{ContractDiff, FailingCall, InvalidContract}

  @handlers %{
    warn_failing_call: [FailingCall],
    warn_contract_not_equal: [ContractDiff],
    warn_contract_subtype: [ContractDiff],
    warn_contract_supertype: [ContractDiff],
    warn_contract_types: [InvalidContract]
  }

  @arrow_prefix "-> "
  @will_never_return "will never return"
  @default_warning_text "Dialyzer warning"
  @indent_two "  "
  @indent_four "    "

  @spec render(map(), keyword()) :: Result.t()
  @doc """
  Builds a `Result` for a raw Dialyzer entry, delegating to handlers when available.

  ## Examples

      iex> entry = %{text: "warning text", match_text: "warning text", path: nil, line: nil, column: nil, code: nil}
      iex> Assay.Formatter.Warning.render(entry).headline
      "warning text"
  """
  def render(entry, opts \\ []) do
    relative = Keyword.get(opts, :relative_path)

    entry
    |> default_result(relative)
    |> apply_handlers(entry, opts)
  end

  defp apply_handlers(result, entry, opts) do
    @handlers
    |> Map.get(entry.code, [])
    |> Enum.reduce(result, fn handler, acc ->
      handler.render(entry, acc, opts)
    end)
  end

  @doc """
  Builds a simple reason block for warning output.

  ## Examples

      iex> Assay.Formatter.Warning.reason_block("will never return")
      ["", "Reason:", "  will never return"]
  """
  def reason_block(nil), do: []

  def reason_block(line) do
    [
      "",
      "Reason:",
      "  #{clean_reason(line)}"
    ]
  end

  @doc """
  Trims Dialyzer prefixes from a reason line.

  ## Examples

      iex> Assay.Formatter.Warning.clean_reason("-> will never return since types differ")
      "will never return since types differ"
  """
  def clean_reason(line) do
    line
    |> String.trim()
    |> String.trim_leading(@arrow_prefix)
  end

  defp default_result(entry, relative) do
    base =
      (entry.text || entry.match_text || @default_warning_text)
      |> String.replace("\r", "")
      |> strip_prefixes(entry, relative)
      |> String.trim_leading(": ")
      |> String.trim()

    lines =
      base
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)

    case lines do
      [] ->
        %Result{headline: @default_warning_text, details: []}

      [headline | tail] ->
        %Result{headline: String.trim(headline), details: tail}
    end
  end

  defp strip_prefixes(message, entry, relative) do
    prefixes =
      [
        location_prefix(relative, entry.line, entry.column),
        location_prefix(relative, entry.line, nil),
        location_prefix(relative, nil, nil),
        location_prefix(entry.path, entry.line, entry.column),
        location_prefix(entry.path, entry.line, nil),
        location_prefix(entry.path, nil, nil)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.reduce(prefixes, message, fn prefix, acc ->
      String.replace_prefix(acc, prefix, "")
    end)
  end

  defp location_prefix(nil, _line, _column), do: nil
  defp location_prefix(path, nil, nil), do: path
  defp location_prefix(path, line, nil), do: "#{path}:#{line}"
  defp location_prefix(path, line, column), do: "#{path}:#{line}:#{column}"

  @doc """
  Formats a module/function into `Module.fun`.

  ## Examples

      iex> Assay.Formatter.Warning.format_call(Foo.Bar, :run)
      "Foo.Bar.run"
  """
  def format_call(module, fun) do
    "#{format_module(module)}.#{fun}"
  end

  defp format_module(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp format_module(other), do: to_string(other)

  defp indent_lines(lines, indent \\ @indent_two) do
    lines
    |> List.flatten()
    |> Enum.map(fn
      "" -> ""
      line -> indent <> line
    end)
  end

  @doc """
  Renders a labeled value block with optional color.

  ## Examples

      iex> Assay.Formatter.Warning.value_block("Expected", ["(atom())"], color?: false)
      ["Expected:", "  (atom())"]
  """
  def value_block(_label, [], _opts), do: []

  def value_block(label, lines, opts) do
    color? = Keyword.get(opts, :color?, false)
    color = Keyword.get(opts, :color)

    [Helpers.colorize(label <> ":", color, color?)] ++ indent_lines(lines)
  end

  @doc """
  Renders a diff section header plus indented lines.

  ## Examples

      iex> Assay.Formatter.Warning.diff_section(["-  (atom())", "+  (binary())"], color?: false)
      ["", "Diff (expected -, actual +):", "    -  (atom())", "    +  (binary())"]
  """
  def diff_section([], _opts), do: []

  def diff_section(lines, opts) do
    color? = Keyword.get(opts, :color?, false)
    header = Helpers.colorize("Diff (expected -, actual +):", :yellow, color?)
    ["", header] ++ indent_lines(lines, @indent_four)
  end

  @doc """
  Convenience wrapper around `Assay.Formatter.Helpers.format_term_lines/1`.
  """
  def format_term_lines(value) do
    Helpers.format_term_lines(value)
  end

  @doc """
  Convenience wrapper around `Assay.Formatter.Helpers.diff_lines/3`.
  """
  def diff_lines(expected_lines, actual_lines, opts) do
    Helpers.diff_lines(expected_lines, actual_lines, opts)
  end

  @doc """
  Extracts the `will never return` reason line from a Dialyzer entry, if present.

  ## Examples

      iex> entry = %{text: "lib/foo.ex:1: -> will never return since types differ"}
      iex> Assay.Formatter.Warning.extract_reason_line(entry)
      "will never return since types differ"
  """
  def extract_reason_line(entry) do
    lines = String.split(entry.text, "\n")

    lines
    |> Enum.find_value(&find_reason_line/1)
    |> case do
      nil -> nil
      line -> line |> String.trim() |> trim_to_reason()
    end
  end

  defp find_reason_line(line) do
    cond do
      String.contains?(line, @arrow_prefix <> @will_never_return) -> line
      String.contains?(line, @will_never_return) -> line
      true -> nil
    end
  end

  defp trim_to_reason(line) do
    case String.split(line, @will_never_return, parts: 2) do
      [_prefix, rest] ->
        suffix = String.trim_leading(rest)
        @will_never_return <> " " <> suffix

      _ ->
        line
    end
  end
end
