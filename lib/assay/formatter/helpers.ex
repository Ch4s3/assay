defmodule Assay.Formatter.Helpers do
  @moduledoc """
  Formatter-agnostic helpers used across warning renderers to normalize Erlang
  terms and render rich diffs.
  """

  @map_prefix "%{"
  @map_suffix "}"
  @indent_two "  "
  @diff_prefix_del "-  "
  @diff_prefix_ins "+  "

  defguardp module_char(char)
            when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or
                   char == ?. or char == ?_ or char == ?!

  @doc """
  Converts Erlang-ish term output into Elixir-friendly string lines.

  Printable binaries are stringified.

  ## Examples

      iex> Assay.Formatter.Helpers.format_term_lines("%{title => <<116,105,116,108,101>>}")
      ["%{:title => \\"title\\"}"]
  """
  def format_term_lines(nil), do: []

  def format_term_lines(value) do
    value
    |> normalize_to_string(value)
    |> maybe_pretty_erlang()
    |> to_string()
    |> render_binaries()
    |> String.trim()
    |> String.split("\n", trim: true)
  end

  defp normalize_to_string(binary, _original) when is_binary(binary), do: binary
  defp normalize_to_string(value, _original) when is_list(value), do: IO.chardata_to_string(value)
  defp normalize_to_string(value, _original), do: inspect(value)

  @erlex_module :"Elixir.Erlex"

  defp maybe_pretty_erlang(text) when is_binary(text) do
    if :erlang.function_exported(@erlex_module, :pretty_print, 1) do
      try do
        :erlang.apply(@erlex_module, :pretty_print, [text])
      rescue
        _ -> text
      catch
        _, _ -> text
      end
    else
      text
    end
  end

  @doc """
  Computes a +/- diff between two lists of strings, highlighting only the differing
  segments while keeping delimiters balanced.

  Returns a flat list of formatted lines (already prefixed with `-  ` or `+  `).

  ## Examples

      iex> Assay.Formatter.Helpers.diff_lines(["(atom())"], ["(binary())"], color?: false)
      ["-  (atom())", "+  (binary())"]
  """
  def diff_lines(expected_lines, actual_lines, opts) do
    color? = Keyword.get(opts, :color?, false)

    case diff_using_map_entries(expected_lines, actual_lines, color?) do
      {:ok, lines} -> lines
      :error -> diff_using_spec_lines(expected_lines, actual_lines, color?)
    end
  end

  defp diff_using_map_entries(expected_lines, actual_lines, color?) do
    diff_map_entries(expected_lines, actual_lines, color?)
  end

  defp diff_using_spec_lines(expected_lines, actual_lines, color?) do
    case diff_spec_lines(expected_lines, actual_lines, color?) do
      {:ok, spec_lines} -> spec_lines
      :error -> diff_using_myers(expected_lines, actual_lines, color?)
    end
  end

  defp diff_using_myers(expected_lines, actual_lines, color?) do
    {ops, pending} = process_myers_operations(expected_lines, actual_lines)

    ops
    |> Enum.concat(Enum.map(pending, &{:del, &1}))
    |> Enum.flat_map(fn
      {:paired, expected, actual} ->
        inline_diff_lines(expected, actual, color?)

      {:del, line} ->
        [diff_line(:del, line, color?)]

      {:ins, line} ->
        [diff_line(:ins, line, color?)]
    end)
  end

  defp process_myers_operations(expected_lines, actual_lines) do
    List.myers_difference(expected_lines, actual_lines)
    |> Enum.reduce({[], []}, fn
      {:eq, _}, acc ->
        acc

      {:del, lines}, {ops, pending} ->
        {ops, pending ++ lines}

      {:ins, lines}, {ops, pending} ->
        count = min(length(pending), length(lines))
        {paired_del, remaining_pending} = Enum.split(pending, count)
        {paired_ins, remaining_ins} = Enum.split(lines, count)

        paired =
          Enum.zip(paired_del, paired_ins)
          |> Enum.map(fn {del_line, ins_line} ->
            {:paired, del_line, ins_line}
          end)

        new_ops =
          ops ++
            paired ++
            Enum.map(remaining_ins, &{:ins, &1})

        {new_ops, remaining_pending}
    end)
  end

  defp inline_diff_lines(expected, actual, color?) do
    segments = diff_segments(expected, actual, color?)

    {expected_line, actual_line} =
      case compact_scope_if_possible(segments, color?) do
        {:compact, exp, act} ->
          {exp, act}

        {:original, exp, act} ->
          {shrink_struct(exp), shrink_struct(act)}
      end

    [
      diff_line(:del, expected_line, color?),
      diff_line(:ins, actual_line, color?)
    ]
  end

  defp diff_map_entries([expected], [actual], color?) do
    with {:ok, expected_map, expected_order} <- map_entries_by_key(expected),
         {:ok, actual_map, actual_order} <- map_entries_by_key(actual) do
      keys =
        expected_order ++
          Enum.reject(actual_order, fn key -> Map.has_key?(expected_map, key) end)

      lines =
        keys
        |> Enum.flat_map(fn key ->
          case {Map.get(expected_map, key), Map.get(actual_map, key)} do
            {nil, nil} ->
              []

            {expected_value, nil} ->
              value = highlight_segment(expected_value, color?)
              [diff_line(:del, entry_line(key, value), color?)]

            {nil, actual_value} ->
              value = highlight_segment(actual_value, color?)
              [diff_line(:ins, entry_line(key, value), color?)]

            {expected_value, actual_value} ->
              diff_map_entry_value(key, expected_value, actual_value, color?)
          end
        end)

      {:ok, lines}
    else
      _ -> :error
    end
  end

  defp diff_map_entries(_, _, _), do: :error

  defp diff_map_entry_value(key, expected_value, actual_value, color?) do
    trimmed_expected = String.trim(expected_value)
    trimmed_actual = String.trim(actual_value)

    if map_literal?(trimmed_expected) and map_literal?(trimmed_actual) do
      expected_render = render_map_value(trimmed_expected, trimmed_actual, color?, :expected)
      actual_render = render_map_value(trimmed_expected, trimmed_actual, color?, :actual)

      [
        diff_line(:del, entry_line(key, expected_render), color?),
        diff_line(:ins, entry_line(key, actual_render), color?)
      ]
    else
      segments = diff_segments(expected_value, actual_value, color?)

      [
        diff_line(:del, entry_line(key, segments.expected_line), color?),
        diff_line(:ins, entry_line(key, segments.actual_line), color?)
      ]
    end
  end

  defp diff_spec_lines([expected], [actual], color?) do
    with {:ok, {expected_args, expected_return}} <- split_spec_line(expected),
         {:ok, {actual_args, actual_return}} <- split_spec_line(actual) do
      arg_segments = diff_segments(expected_args, actual_args, color?)
      return_segments = diff_segments(expected_return, actual_return, color?)

      expected_line =
        "(" <> arg_segments.expected_line <> ") :: " <> return_segments.expected_line

      actual_line =
        "(" <> arg_segments.actual_line <> ") :: " <> return_segments.actual_line

      {:ok,
       [
         diff_line(:del, expected_line, color?),
         diff_line(:ins, actual_line, color?)
       ]}
    else
      _ -> :error
    end
  end

  defp diff_spec_lines(_, _, _), do: :error

  defp entry_line(key, value) do
    render_binaries("#{key} => #{value}")
  end

  defp render_map_value(value, other_value, color?, type) do
    with {:ok, map, order} <- map_entries_by_key(value),
         {:ok, other_map, other_order} <- map_entries_by_key(other_value) do
      keys =
        case type do
          :expected -> order
          :actual -> other_order
        end

      entries =
        keys
        |> Enum.map(fn key ->
          val = Map.get(map, key)
          other_val = Map.get(other_map, key)
          rendered = render_map_entry_value(val, other_val, color?, type)
          "#{key} => #{rendered}"
        end)

      @map_prefix <> Enum.join(entries, ", ") <> @map_suffix
    else
      _ ->
        highlight_value_segment(value, other_value, color?, type)
    end
  end

  defp render_map_entry_value(val, other_val, color?, type) do
    cond do
      is_nil(val) and is_nil(other_val) ->
        nil

      is_nil(other_val) ->
        String.trim(val)

      is_nil(val) ->
        String.trim(other_val)

      map_literal?(String.trim(val)) and map_literal?(String.trim(other_val)) ->
        render_map_value(String.trim(val), String.trim(other_val), color?, type)

      true ->
        highlight_value_segment(val, other_val, color?, type)
    end
  end

  defp highlight_value_segment(value, other_value, color?, type) do
    segments = diff_segments(value, other_value, color?)

    case type do
      :expected -> segments.expected_line
      :actual -> segments.actual_line
    end
  end

  defp map_entries_by_key(text) do
    with {:ok, entries} <- map_entry_list(text) do
      Enum.reduce_while(entries, {:ok, %{}, MapSet.new(), []}, fn entry,
                                                                  {:ok, map, order_set,
                                                                   order_list} ->
        case split_key_value(entry) do
          {key, value} when is_binary(value) ->
            normalized = String.trim(key)
            updated_map = Map.put(map, normalized, String.trim(value))

            {updated_order_set, updated_order_list} =
              update_order_tracking(order_set, order_list, normalized)

            {:cont, {:ok, updated_map, updated_order_set, updated_order_list}}

          _ ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, map, _order_set, order_list} -> {:ok, map, Enum.reverse(order_list)}
        error -> error
      end
    end
  end

  defp update_order_tracking(order_set, order_list, normalized) do
    if MapSet.member?(order_set, normalized) do
      {order_set, order_list}
    else
      {MapSet.put(order_set, normalized), [normalized | order_list]}
    end
  end

  defp map_entry_list(text) do
    case map_inner_text(text) do
      {:ok, inner} ->
        entries =
          inner
          |> split_map_entries()
          |> Enum.reject(&(&1 == "" or &1 == "..."))

        {:ok, entries}

      _ ->
        :error
    end
  end

  defp diff_segments(expected, actual, color?) do
    {prefix, expected_diff, actual_diff, expected_suffix, actual_suffix} =
      find_common_prefix_suffix(expected, actual)

    {balanced_expected_diff, balanced_expected_suffix, balanced_actual_diff,
     balanced_actual_suffix} =
      rebalance_segments(prefix, expected_diff, expected_suffix, actual_diff, actual_suffix)

    {final_expected_diff, final_actual_diff, shared_closers} =
      detach_shared_closers(balanced_expected_diff, balanced_actual_diff)

    final_expected_suffix = shared_closers <> balanced_expected_suffix
    final_actual_suffix = shared_closers <> balanced_actual_suffix

    build_segment_result(
      prefix,
      final_expected_diff,
      final_actual_diff,
      final_expected_suffix,
      final_actual_suffix,
      expected,
      actual,
      color?
    )
  end

  defp find_common_prefix_suffix(expected, actual) do
    {prefix, rest_expected, rest_actual} = split_common_prefix(expected, actual)
    suffix_len = common_suffix_length(rest_expected, rest_actual)
    {expected_diff, expected_suffix} = split_suffix(rest_expected, suffix_len)
    {actual_diff, actual_suffix} = split_suffix(rest_actual, suffix_len)
    {prefix, expected_diff, actual_diff, expected_suffix, actual_suffix}
  end

  defp rebalance_segments(prefix, expected_diff, expected_suffix, actual_diff, actual_suffix) do
    {balanced_expected_diff, balanced_expected_suffix} =
      rebalance_segment(prefix, expected_diff, expected_suffix)

    {balanced_actual_diff, balanced_actual_suffix} =
      rebalance_segment(prefix, actual_diff, actual_suffix)

    {balanced_expected_diff, balanced_expected_suffix, balanced_actual_diff,
     balanced_actual_suffix}
  end

  defp detach_shared_closers(expected_diff, actual_diff) do
    detach_shared_trailing_closers(expected_diff, actual_diff)
  end

  defp build_segment_result(
         prefix,
         expected_diff,
         actual_diff,
         expected_suffix,
         actual_suffix,
         original_expected,
         original_actual,
         color?
       ) do
    highlighted_expected_diff = highlight_segment(expected_diff, color?)
    highlighted_actual_diff = highlight_segment(actual_diff, color?)

    %{
      prefix: prefix,
      expected_diff: expected_diff,
      expected_suffix: expected_suffix,
      actual_diff: actual_diff,
      actual_suffix: actual_suffix,
      highlighted_expected_diff: highlighted_expected_diff,
      highlighted_actual_diff: highlighted_actual_diff,
      expected_line: prefix <> highlighted_expected_diff <> expected_suffix,
      actual_line: prefix <> highlighted_actual_diff <> actual_suffix,
      original_expected: original_expected,
      original_actual: original_actual
    }
  end

  defp compact_scope_if_possible(segments, color?) do
    case try_compact_struct(segments) do
      {:compact, _, _} = compact ->
        compact

      :error ->
        case try_compact_map(segments, color?) do
          {:compact, _, _} = compact ->
            compact

          :error ->
            {:original, segments.expected_line, segments.actual_line}
        end
    end
  end

  defp try_compact_struct(%{prefix: prefix} = segments) do
    with true <- inside_struct?(prefix),
         {:ok, struct} <- extract_struct_name(segments.original_expected),
         {:ok, field} <- extract_field_name(prefix) do
      expected_line =
        compact_struct_line(struct, field, segments.highlighted_expected_diff)

      actual_line =
        compact_struct_line(struct, field, segments.highlighted_actual_diff)

      {:compact, expected_line, actual_line}
    else
      _ -> :error
    end
  end

  defp try_compact_map(%{prefix: prefix} = segments, color?) do
    with true <- inside_map?(prefix),
         {:ok, field} <- extract_map_field_name(prefix),
         {:ok, expected_entry} <- extract_map_entry(segments.original_expected, field),
         {:ok, actual_entry} <- extract_map_entry(segments.original_actual, field) do
      entry_segments = diff_segments(expected_entry, actual_entry, color?)

      expected_line =
        compact_map_line(field, entry_segments.highlighted_expected_diff)

      actual_line =
        compact_map_line(field, entry_segments.highlighted_actual_diff)

      {:compact, expected_line, actual_line}
    else
      _ -> :error
    end
  end

  defp compact_struct_line(struct, field, highlighted_value) do
    "(#{struct}{..., #{field}" <> highlighted_value <> "})"
  end

  defp compact_map_line(field, highlighted_value) do
    "(" <> @map_prefix <> "..., #{field}" <> highlighted_value <> "})"
  end

  defp extract_struct_name(line) do
    case Regex.run(~r/%([\w\.!]+)\{/, line) do
      [match, _name] ->
        name =
          match
          |> String.trim_leading("(")
          |> String.trim_trailing("{")

        {:ok, name}

      _ ->
        :error
    end
  end

  defp extract_field_name(prefix) do
    case Regex.scan(~r/(:[\w\?!]+ => )/, prefix) do
      [] ->
        :error

      matches ->
        {:ok, matches |> List.last() |> List.first()}
    end
  end

  defp map_literal?(text) do
    String.starts_with?(text, @map_prefix) and String.ends_with?(text, @map_suffix)
  end

  defp extract_map_field_name(prefix) do
    case :binary.matches(prefix, @map_prefix) do
      [] ->
        :error

      matches ->
        {index, length} = List.last(matches)
        inner = binary_part(prefix, index + length, byte_size(prefix) - (index + length))

        inner
        |> split_map_entries()
        |> Enum.reject(&(&1 == "" or &1 == "..."))
        |> List.last()
        |> case do
          nil ->
            :error

          entry ->
            {key, _value} = split_key_value(entry)
            {:ok, String.trim(key) <> " => "}
        end
    end
  end

  defp extract_map_entry(text, field) do
    with {:ok, inner} <- map_inner_text(text),
         entries when is_list(entries) <- split_map_entries(inner),
         entry when is_binary(entry) <- Enum.find(entries, &map_entry_matches?(&1, field)) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp map_inner_text(text) do
    trimmed = String.trim(text)

    cond do
      map_literal?(trimmed) ->
        {:ok,
         trimmed
         |> String.trim_leading(@map_prefix)
         |> String.trim_trailing(@map_suffix)
         |> String.trim()}

      wraps_in_parens?(trimmed) ->
        inner =
          trimmed
          |> String.slice(1, byte_size(trimmed) - 2)
          |> String.trim()

        if map_literal?(inner) do
          {:ok,
           inner
           |> String.trim_leading(@map_prefix)
           |> String.trim_trailing(@map_suffix)
           |> String.trim()}
        else
          :error
        end

      true ->
        :error
    end
  end

  defp map_entry_matches?(entry, field) do
    {key, _value} = split_key_value(entry)
    String.trim(key) <> " => " == field
  end

  defp shrink_struct(line) do
    shrink_struct_recursive(line, "")
  end

  defp shrink_struct_recursive(<<>>, acc), do: acc

  defp shrink_struct_recursive(<<"%", rest::binary>> = original, acc) do
    case take_struct(rest) do
      {:ok, module, remainder} ->
        shrink_struct_recursive(remainder, acc <> "%" <> module <> "{...}")

      :error ->
        <<char::utf8, tail::binary>> = original
        shrink_struct_recursive(tail, acc <> <<char::utf8>>)
    end
  end

  defp shrink_struct_recursive(<<char::utf8, rest::binary>>, acc) do
    shrink_struct_recursive(rest, acc <> <<char::utf8>>)
  end

  defp take_struct(binary) do
    with {:ok, module, rest} <- take_module(binary, "") do
      case rest do
        <<"{", after_open::binary>> ->
          case skip_braces(after_open, 1) do
            {:ok, remainder} -> {:ok, module, remainder}
            :error -> :error
          end

        _ ->
          :error
      end
    end
  end

  defp take_module(<<char::utf8, rest::binary>>, acc) when module_char(char) do
    take_module(rest, <<acc::binary, char::utf8>>)
  end

  defp take_module(rest, acc) when acc != "" do
    {:ok, acc, rest}
  end

  defp take_module(_rest, _acc), do: :error

  defp skip_braces(<<>>, _depth), do: :error

  defp skip_braces(<<"{", rest::binary>>, depth), do: skip_braces(rest, depth + 1)
  defp skip_braces(<<"}", rest::binary>>, 1), do: {:ok, rest}
  defp skip_braces(<<"}", rest::binary>>, depth), do: skip_braces(rest, depth - 1)
  defp skip_braces(<<_char::utf8, rest::binary>>, depth), do: skip_braces(rest, depth)

  defp inside_struct?(prefix) do
    case :binary.matches(prefix, "%") do
      [] ->
        false

      matches ->
        {index, _} = List.last(matches)
        length = byte_size(prefix) - index
        segment = binary_part(prefix, index, length)
        brace_balance(segment) > 0
    end
  end

  defp inside_map?(prefix) do
    case :binary.matches(prefix, @map_prefix) do
      [] ->
        false

      matches ->
        {index, _length} = List.last(matches)
        length = byte_size(prefix) - index
        segment = binary_part(prefix, index, length)
        brace_balance(segment) > 0
    end
  end

  defp brace_balance(segment) do
    segment
    |> String.graphemes()
    |> Enum.reduce(0, fn
      "{", acc -> acc + 1
      "}", acc when acc > 0 -> acc - 1
      "}", acc -> acc
      _, acc -> acc
    end)
  end

  defp diff_line(type, text, color?) do
    prefix = diff_prefix(type)
    color = diff_color(type)
    lines = pretty_multiline(text)

    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} ->
        line
        |> then(&balance_line(prefix <> &1))
        |> colorize(color, color?)

      {line, _} ->
        indentation = String.duplicate(" ", String.length(prefix))

        line
        |> then(&balance_line(indentation <> &1))
        |> colorize(color, color?)
    end)
  end

  defp diff_prefix(:del), do: @diff_prefix_del
  defp diff_prefix(:ins), do: @diff_prefix_ins

  defp diff_color(:del), do: :red
  defp diff_color(:ins), do: :green

  defp highlight_segment("", _color?), do: ""

  defp highlight_segment(text, color?) do
    colorize(text, :yellow, color?)
  end

  defp split_common_prefix(a, b) do
    split_common_prefix(a, b, "")
  end

  defp split_common_prefix(<<>>, rest, acc), do: {acc, "", rest}
  defp split_common_prefix(rest, <<>>, acc), do: {acc, rest, ""}

  defp split_common_prefix(<<char::utf8, rest_a::binary>>, <<char::utf8, rest_b::binary>>, acc) do
    split_common_prefix(rest_a, rest_b, <<acc::binary, char::utf8>>)
  end

  defp split_common_prefix(rest_a, rest_b, acc), do: {acc, rest_a, rest_b}

  defp common_suffix_length(a, b) do
    ra = Enum.reverse(String.graphemes(a))
    rb = Enum.reverse(String.graphemes(b))

    Enum.zip(ra, rb)
    |> Enum.reduce_while(0, fn
      {char, char}, acc -> {:cont, acc + 1}
      _, acc -> {:halt, acc}
    end)
  end

  defp split_suffix(text, 0), do: {text, ""}

  defp split_suffix(text, count) do
    length = String.length(text)

    if count >= length do
      {"", text}
    else
      keep = length - count
      {String.slice(text, 0, keep), String.slice(text, keep, count)}
    end
  end

  defp render_binaries(text) do
    text
    |> replace_printable_binaries()
    |> stringify_bit_specs()
    |> normalize_binary_commas()
  end

  defp replace_printable_binaries(text) do
    matches = Regex.scan(~r/<<([\d,\s,]+)>>/, text)

    Enum.reduce(matches, text, fn
      [full, inner], acc ->
        replacement =
          case parse_printable(inner) do
            {:ok, binary} -> inspect(binary)
            :error -> full
          end

        String.replace(acc, full, replacement)

      _, acc ->
        acc
    end)
  end

  defp stringify_bit_specs(text) do
    Regex.replace(~r/(?<!")<<\s*_+[^>]*::[^>]*>>(?!")/, text, fn match ->
      inspect(String.trim(match))
    end)
  end

  defp normalize_binary_commas(text) do
    Regex.replace(~r/<<[^<>]+>>/, text, fn match ->
      Regex.replace(~r/(\d),(?=\d)/, match, "\\1, ")
    end)
  end

  defp parse_printable(inner) do
    segments =
      inner
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    with {:ok, values} <- parse_bytes(segments),
         binary <- :erlang.list_to_binary(values),
         true <- String.printable?(binary) do
      {:ok, binary}
    else
      _ -> :error
    end
  end

  defp parse_bytes(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, acc} ->
      case Integer.parse(segment) do
        {value, ""} when value in 0..255 ->
          {:cont, {:ok, [value | acc]}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  @doc """
  Wraps `text` with ANSI color codes when `enabled?` is true.
  """
  def colorize(text, _color, false), do: text
  def colorize(text, nil, _color?), do: text

  def colorize(text, color, true) do
    color_code =
      color
      |> IO.ANSI.format_fragment(true)
      |> IO.iodata_to_binary()

    reset_code =
      :reset
      |> IO.ANSI.format_fragment(true)
      |> IO.iodata_to_binary()

    tinted =
      text
      |> String.replace(reset_code, reset_code <> color_code)

    [color_code, tinted, reset_code]
    |> IO.iodata_to_binary()
  end

  defp pretty_multiline(text) do
    trimmed = String.trim(text)
    {content, prefix, suffix} = extract_ansi_wrappers(trimmed)

    lines =
      cond do
        wraps_in_parens?(content) ->
          inner =
            content
            |> String.slice(1, byte_size(content) - 2)
            |> String.trim()

          wrap_parentheses(pretty_multiline(inner))

        String.starts_with?(content, @map_prefix) and String.ends_with?(content, @map_suffix) ->
          format_map_lines(content)

        true ->
          [content]
      end

    reattach_ansi(lines, prefix, suffix)
  end

  defp format_map_lines(map_text, level \\ 0) do
    inner =
      map_text
      |> String.trim_leading(@map_prefix)
      |> String.trim_trailing(@map_suffix)
      |> String.trim()

    entries = split_map_entries(inner)

    if length(entries) <= 1 do
      [String.duplicate(@indent_two, level) <> map_text]
    else
      indent = String.duplicate(@indent_two, level)
      last_index = length(entries) - 1

      formatted = format_map_entries_with_suffixes(entries, level, last_index)

      [indent <> @map_prefix] ++ formatted ++ [indent <> @map_suffix]
    end
  end

  defp format_map_entries_with_suffixes(entries, level, last_index) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      suffix = if idx < last_index, do: ",", else: ""
      format_map_entry(entry, level + 1, suffix)
    end)
  end

  defp format_map_entry(entry, level, suffix) do
    indent = String.duplicate(@indent_two, level)
    trimmed = String.trim(entry)

    case split_key_value(trimmed) do
      {key, value} when is_binary(value) ->
        value_trimmed = String.trim_leading(value)

        if String.starts_with?(value_trimmed, @map_prefix) do
          format_nested_map_entry(indent, key, value_trimmed, level, suffix)
        else
          [indent <> trimmed <> suffix]
        end

      _ ->
        [indent <> trimmed <> suffix]
    end
  end

  defp format_nested_map_entry(indent, key, value_trimmed, level, suffix) do
    formatted = format_map_lines(value_trimmed, level + 1)
    [head | tail] = formatted
    head_line = indent <> key <> " => " <> String.trim_leading(head)

    lines = if tail == [], do: [head_line], else: [head_line | tail]
    attach_suffix(lines, suffix)
  end

  defp split_map_entries(inner) do
    inner
    |> split_map_entries_recursive([], "", %{brace: 0, bracket: 0, paren: 0, bit: 0})
    |> Enum.reject(&(&1 == ""))
  end

  defp split_key_value(entry) do
    case String.split(entry, "=>", parts: 2) do
      [key, value] ->
        {String.trim_trailing(key), String.trim_leading(value)}

      _ ->
        {entry, nil}
    end
  end

  defp split_map_entries_recursive(<<>>, acc, current, _depth) do
    entry = String.trim(current)
    entries = if entry == "", do: acc, else: [entry | acc]
    Enum.reverse(entries)
  end

  defp split_map_entries_recursive(<<"\e[", rest::binary>>, acc, current, depth) do
    handle_ansi_sequence(rest, acc, current, depth)
  end

  defp split_map_entries_recursive(<<?,, rest::binary>>, acc, current, depth) do
    handle_comma(rest, acc, current, depth)
  end

  defp split_map_entries_recursive(<<?<, ?<, rest::binary>>, acc, current, depth) do
    handle_bitstring_open(rest, acc, current, depth)
  end

  defp split_map_entries_recursive(<<?>, ?>, rest::binary>>, acc, current, %{bit: bit} = depth)
       when bit > 0 do
    handle_bitstring_close(rest, acc, current, depth)
  end

  defp split_map_entries_recursive(<<char, rest::binary>>, acc, current, depth) do
    updated_depth = update_depth(char, depth)
    split_map_entries_recursive(rest, acc, current <> <<char>>, updated_depth)
  end

  defp handle_ansi_sequence(rest, acc, current, depth) do
    {sequence, remaining} = consume_ansi_sequence(rest, "")
    split_map_entries_recursive(remaining, acc, current <> "\e[" <> sequence, depth)
  end

  defp handle_comma(rest, acc, current, depth) do
    if top_level?(depth) do
      entry = String.trim(current)
      new_acc = if entry == "", do: acc, else: [entry | acc]
      split_map_entries_recursive(rest, new_acc, "", depth)
    else
      split_map_entries_recursive(rest, acc, current <> ",", depth)
    end
  end

  defp handle_bitstring_open(rest, acc, current, depth) do
    updated_depth = %{depth | bit: depth.bit + 1}
    split_map_entries_recursive(rest, acc, current <> "<<", updated_depth)
  end

  defp handle_bitstring_close(rest, acc, current, depth) do
    updated_depth = %{depth | bit: depth.bit - 1}
    split_map_entries_recursive(rest, acc, current <> ">>", updated_depth)
  end

  defp update_depth(char, depth) do
    case char do
      ?{ -> %{depth | brace: depth.brace + 1}
      ?} when depth.brace > 0 -> %{depth | brace: depth.brace - 1}
      ?[ -> %{depth | bracket: depth.bracket + 1}
      ?] when depth.bracket > 0 -> %{depth | bracket: depth.bracket - 1}
      ?( -> %{depth | paren: depth.paren + 1}
      ?) when depth.paren > 0 -> %{depth | paren: depth.paren - 1}
      _ -> depth
    end
  end

  defp consume_ansi_sequence(<<>>, acc), do: {acc, ""}

  defp consume_ansi_sequence(<<char, rest::binary>>, acc) do
    updated = acc <> <<char>>

    if char == ?m do
      {updated, rest}
    else
      consume_ansi_sequence(rest, updated)
    end
  end

  defp top_level?(%{brace: 0, bracket: 0, paren: 0, bit: 0}), do: true
  defp top_level?(_), do: false

  defp wraps_in_parens?(text) do
    String.starts_with?(text, "(") and String.ends_with?(text, ")") and byte_size(text) > 1
  end

  defp wrap_parentheses([single]), do: ["(" <> single <> ")"]

  defp wrap_parentheses([first | rest]) do
    {middle, [last]} = Enum.split(rest, length(rest) - 1)
    ["(" <> first] ++ middle ++ [last <> ")"]
  end

  defp extract_ansi_wrappers(text) do
    {prefix, remainder} = take_leading_ansi(text)
    {core, suffix} = take_trailing_ansi(remainder)
    {core, prefix, suffix}
  end

  defp take_leading_ansi(text) do
    case Regex.run(~r/^(?:\e\[[0-9;]*m)+/, text) do
      [match] ->
        size = byte_size(match)
        {match, binary_part(text, size, byte_size(text) - size)}

      _ ->
        {"", text}
    end
  end

  defp take_trailing_ansi(text) do
    case Regex.run(~r/(?:\e\[[0-9;]*m)+$/, text) do
      [match] ->
        size = byte_size(match)
        {binary_part(text, 0, byte_size(text) - size), match}

      _ ->
        {text, ""}
    end
  end

  defp reattach_ansi([single], prefix, suffix), do: [prefix <> single <> suffix]

  defp reattach_ansi([first | rest], prefix, suffix) do
    {middle, [last]} = Enum.split(rest, length(rest) - 1)
    [prefix <> first] ++ middle ++ [last <> suffix]
  end

  defp attach_suffix(lines, suffix) do
    case Enum.split(lines, length(lines) - 1) do
      {[], [last]} ->
        [last <> suffix]

      {init, [last]} ->
        init ++ [last <> suffix]

      _ ->
        lines
    end
  end

  defp rebalance_segment(prefix, diff, suffix) do
    closers =
      (prefix <> diff)
      |> strip_ansi()
      |> unmatched_closers()

    {balanced_diff, balanced_suffix} =
      if closers == [] do
        {diff, suffix}
      else
        case take_needed_closers(suffix, closers) do
          {taken, remaining} when taken != "" ->
            {diff <> taken, remaining}

          _ ->
            {diff, suffix}
        end
      end

    pull_shared_closers(balanced_diff, balanced_suffix)
  end

  defp unmatched_closers(text) do
    text
    |> String.graphemes()
    |> Enum.reduce([], fn char, stack ->
      cond do
        char in ["(", "[", "{"] ->
          [char | stack]

        char == ")" ->
          pop_matching(stack, "(")

        char == "]" ->
          pop_matching(stack, "[")

        char == "}" ->
          pop_matching(stack, "{")

        true ->
          stack
      end
    end)
    |> Enum.map(&closing_for/1)
  end

  defp pop_matching([expected | rest], expected), do: rest
  defp pop_matching(stack, _), do: stack

  defp closing_for("("), do: ")"
  defp closing_for("["), do: "]"
  defp closing_for("{"), do: "}"
  defp closing_for(char), do: char

  defp take_needed_closers(text, []), do: {"", text}

  defp take_needed_closers(text, [close | rest]) do
    {leading, after_leading} = take_leading_whitespace(text)

    cond do
      after_leading == "" ->
        {"", text}

      String.starts_with?(after_leading, close) ->
        close_size = byte_size(close)
        <<_::binary-size(close_size), remaining::binary>> = after_leading
        {next_chunk, final} = take_needed_closers(remaining, rest)
        {leading <> close <> next_chunk, final}

      true ->
        {"", text}
    end
  end

  defp take_leading_whitespace(text) do
    {leading, rest} =
      text
      |> String.to_charlist()
      |> Enum.split_while(&(&1 in [?\s, ?\t, ?\n, ?\r]))

    {to_string(leading), to_string(rest)}
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[\d;]*m/, text, "")
  end

  defp balance_line(line) do
    closers =
      line
      |> strip_ansi()
      |> unmatched_closers()
      |> Enum.join("")

    if closers == "" do
      line
    else
      line <> closers
    end
  end

  defp pull_shared_closers(diff, suffix) do
    {leading, rest} = take_leading_whitespace(suffix)
    {closers, remaining} = consume_closers(rest, "")

    if closers == "" do
      {diff, suffix}
    else
      {diff <> closers, leading <> remaining}
    end
  end

  defp consume_closers(<<>>, acc), do: {acc, ""}

  defp consume_closers(<<char::utf8, rest::binary>>, acc) when char in ~c/)]}/ do
    consume_closers(rest, acc <> <<char::utf8>>)
  end

  defp consume_closers(text, acc), do: {acc, text}

  defp detach_shared_trailing_closers(expected, actual) do
    {trimmed_expected, trimmed_actual, closers} =
      do_detach_shared_trailing(expected, actual, [])

    {trimmed_expected, trimmed_actual, Enum.join(Enum.reverse(closers))}
  end

  defp do_detach_shared_trailing("", actual, acc), do: {"", actual, acc}
  defp do_detach_shared_trailing(expected, "", acc), do: {expected, "", acc}

  defp do_detach_shared_trailing(expected, actual, acc) do
    original_expected = expected
    original_actual = actual
    {expected_char, expected_rest} = pop_trailing_char(expected)
    {actual_char, actual_rest} = pop_trailing_char(actual)

    if expected_char == actual_char and expected_char in [")", "]", "}"] do
      do_detach_shared_trailing(expected_rest, actual_rest, [expected_char | acc])
    else
      {original_expected, original_actual, acc}
    end
  end

  defp pop_trailing_char(""), do: {nil, ""}

  defp pop_trailing_char(text) do
    len = String.length(text)
    char = String.at(text, -1)
    rest = String.slice(text, 0, len - 1)
    {char, rest}
  end

  defp split_spec_line(line) do
    trimmed = String.trim(line)

    with true <- String.starts_with?(trimmed, "("),
         {:ok, inner, rest} <- take_outer_paren(trimmed) do
      remainder = String.trim_leading(rest)

      if String.starts_with?(remainder, "::") do
        return_spec =
          remainder
          |> String.trim_leading("::")
          |> String.trim()

        {:ok, {String.trim(inner), return_spec}}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp take_outer_paren(<<"(", rest::binary>>) do
    consume_paren(rest, 1, "")
  end

  defp take_outer_paren(_), do: :error

  defp consume_paren(<<>>, _depth, _acc), do: :error

  defp consume_paren(<<")", tail::binary>>, 1, acc), do: {:ok, acc, tail}

  defp consume_paren(<<")", tail::binary>>, depth, acc) when depth > 1 do
    consume_paren(tail, depth - 1, acc <> ")")
  end

  defp consume_paren(<<"(", tail::binary>>, depth, acc) do
    consume_paren(tail, depth + 1, acc <> "(")
  end

  defp consume_paren(<<char::utf8, tail::binary>>, depth, acc) do
    consume_paren(tail, depth, acc <> <<char::utf8>>)
  end
end
