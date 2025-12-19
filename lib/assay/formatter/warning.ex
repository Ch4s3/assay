defmodule Assay.Formatter.Warning do
  @moduledoc false

  defmodule Result do
    @moduledoc false
    defstruct [:headline, details: []]
  end

  alias __MODULE__.Result

  defguardp module_char(char)
            when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or
                   char == ?. or char == ?_ or char == ?!

  @spec render(map(), keyword()) :: Result.t()
  def render(entry, opts \\ []) do
    relative = Keyword.get(opts, :relative_path)

    entry
    |> default_result(relative)
    |> maybe_enhance(entry, relative, opts)
  end

  defp maybe_enhance(result, %{code: :warn_failing_call} = entry, relative, opts) do
    failing_call(entry, result, relative, opts)
  end

  defp maybe_enhance(result, _entry, _relative, _opts), do: result

  defp failing_call(
         %{raw: {:warn_failing_call, _loc, {:call, parts}}} = entry,
         result,
         _relative,
         opts
       ) do
    case parts do
      [module, fun, actual, _positions, _mode, expected | _tail] ->
        call = format_call(module, fun)
        reason_line = extract_reason_line(entry)
        actual_lines = format_term_lines(actual)
        expected_lines = format_term_lines(expected)
        diff_lines = diff_lines(expected_lines, actual_lines, opts)
        color? = Keyword.get(opts, :color?, false)

        reason_block = reason_block(reason_line)

        details =
          [
            ["Call: #{call}"],
            reason_block,
            [""],
            value_block("Expected (success typing)", expected_lines,
              color?: color?,
              color: :red
            ),
            [""],
            value_block("Actual (call arguments)", actual_lines,
              color?: color?,
              color: :green
            ),
            diff_section(diff_lines, color?: color?)
          ]
          |> List.flatten()
          |> Enum.reject(&is_nil/1)

        headline =
          case entry.relative_path do
            nil -> "Failure in #{call}"
            relative -> "#{relative}:#{entry.line}: #{call} will fail"
          end

        %Result{headline: headline, details: details}

      _ ->
        result
    end
  end

  defp failing_call(_entry, result, _relative, _opts), do: result

  defp reason_block(nil), do: []

  defp reason_block(line) do
    [
      "",
      "Reason:",
      "  #{clean_reason(line)}"
    ]
  end

  defp clean_reason(line) do
    line
    |> String.trim()
    |> String.trim_leading("-> ")
  end

  defp default_result(entry, relative) do
    base =
      (entry.text || entry.match_text || "Dialyzer warning")
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
        %Result{headline: "Dialyzer warning", details: []}

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

  defp format_call(module, fun) do
    "#{format_module(module)}.#{fun}"
  end

  defp format_module(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp format_module(other), do: to_string(other)

  defp indent_lines(lines, indent \\ "  ") do
    lines
    |> List.flatten()
    |> Enum.map(fn
      "" -> ""
      line -> indent <> line
    end)
  end

  defp value_block(_label, [], _opts), do: []

  defp value_block(label, lines, opts) do
    color? = Keyword.get(opts, :color?, false)
    color = Keyword.get(opts, :color)

    [colorize(label <> ":", color, color?)] ++ indent_lines(lines)
  end

  defp diff_section([], _opts), do: []

  defp diff_section(lines, opts) do
    color? = Keyword.get(opts, :color?, false)
    header = colorize("Diff (expected -, actual +):", :yellow, color?)
    ["", header] ++ indent_lines(lines, "    ")
  end

  defp format_term_lines(nil), do: []

  defp format_term_lines(value) do
    value
    |> to_string_maybe(value)
    |> maybe_pretty_erlang()
    |> to_string()
    |> render_binaries()
    |> String.trim()
    |> String.split("\n", trim: true)
  end

  defp to_string_maybe(binary, _original) when is_binary(binary), do: binary
  defp to_string_maybe(value, _original) when is_list(value), do: IO.chardata_to_string(value)

  defp to_string_maybe(value, _original) when is_binary(value) do
    if String.valid?(value) do
      inspect(value)
    else
      inspect(value)
    end
  end

  defp to_string_maybe(value, _original), do: inspect(value)

  defp extract_reason_line(entry) do
    lines = String.split(entry.text, "\n")

    lines
    |> Enum.find(&String.contains?(&1, "-> will never return"))
    |> case do
      nil ->
        lines
        |> Enum.find(&String.contains?(&1, "will never return"))

      line ->
        line
    end
    |> case do
      nil ->
        nil

      line ->
        line
        |> String.trim()
        |> trim_to_reason()
    end
  end

  defp trim_to_reason(line) do
    case String.split(line, "will never return", parts: 2) do
      [_prefix, rest] ->
        suffix = String.trim_leading(rest || "")
        "will never return " <> suffix

      _ ->
        line
    end
  end

  defp maybe_pretty_erlang(text) when is_binary(text) do
    if Code.ensure_loaded?(Erlex) do
      try do
        Erlex.pretty_print(text)
      rescue
        _ -> text
      catch
        _, _ -> text
      end
    else
      text
    end
  end

  defp diff_lines(expected_lines, actual_lines, opts) do
    color? = Keyword.get(opts, :color?, false)

    case diff_map_entries(expected_lines, actual_lines, color?) do
      {:ok, lines} ->
        lines

      :error ->
        {ops, pending} =
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
  end

  defp inline_diff_lines(expected, actual, color?) do
    segments = diff_segments(expected, actual, color?)

    {expected_line, actual_line} =
      case maybe_compact_scope(segments, color?) do
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
        end)

      {:ok, lines}
    else
      _ -> :error
    end
  end

  defp diff_map_entries(_, _, _), do: :error

  defp entry_line(key, value) do
    "#{key} => #{value}"
    |> render_binaries()
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

          rendered =
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

          "#{key} => #{rendered}"
        end)

      "%{" <> Enum.join(entries, ", ") <> "}"
    else
      _ ->
        highlight_value_segment(value, other_value, color?, type)
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
      Enum.reduce_while(entries, {:ok, %{}, []}, fn entry, {:ok, map, order} ->
        case split_key_value(entry) do
          {key, value} ->
            normalized = String.trim(key)
            updated_map = Map.put(map, normalized, String.trim(value))
            updated_order = if normalized in order, do: order, else: order ++ [normalized]
            {:cont, {:ok, updated_map, updated_order}}

          _ ->
            {:halt, :error}
        end
      end)
    end
  end

  defp map_entry_list(text) do
    with {:ok, inner} <- map_inner_text(text) do
      entries =
        inner
        |> split_map_entries()
        |> Enum.reject(&(&1 == "" or &1 == "..."))

      {:ok, entries}
    else
      _ -> :error
    end
  end

  defp diff_segments(expected, actual, color?) do
    {prefix, rest_expected, rest_actual} = split_common_prefix(expected, actual)
    suffix_len = common_suffix_length(rest_expected, rest_actual)
    {expected_diff, expected_suffix} = split_suffix(rest_expected, suffix_len)
    {actual_diff, actual_suffix} = split_suffix(rest_actual, suffix_len)
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
      original_expected: expected,
      original_actual: actual
    }
  end

  defp maybe_compact_scope(segments, color?) do
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
    "(%{..., #{field}" <> highlighted_value <> "})"
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
    String.starts_with?(text, "%{") and String.ends_with?(text, "}")
  end

  defp extract_map_field_name(prefix) do
    case :binary.matches(prefix, "%{") do
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
         |> String.trim_leading("%{")
         |> String.trim_trailing("}") |> String.trim()}

      wraps_in_parens?(trimmed) ->
        inner =
          trimmed
          |> String.slice(1, byte_size(trimmed) - 2)
          |> String.trim()

        if map_literal?(inner) do
          {:ok,
           inner
           |> String.trim_leading("%{")
           |> String.trim_trailing("}") |> String.trim()}
        else
          :error
        end

      true ->
        :error
    end
  end

  defp map_entry_matches?(entry, field) do
    case split_key_value(entry) do
      {key, _value} when is_binary(key) ->
        String.trim(key) <> " => " == field

      _ ->
        false
    end
  end

  defp shrink_struct(line) do
    do_shrink_struct(line, "")
  end

  defp do_shrink_struct(<<>>, acc), do: acc

  defp do_shrink_struct(<<"%", rest::binary>> = original, acc) do
    case take_struct(rest) do
      {:ok, module, remainder} ->
        do_shrink_struct(remainder, acc <> "%" <> module <> "{...}")

      :error ->
        <<char::utf8, tail::binary>> = original
        do_shrink_struct(tail, acc <> <<char::utf8>>)
    end
  end

  defp do_shrink_struct(<<char::utf8, rest::binary>>, acc) do
    do_shrink_struct(rest, acc <> <<char::utf8>>)
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
    case :binary.matches(prefix, "%{") do
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
        colorize(prefix <> line, color, color?)

      {line, _} ->
        colorize(String.duplicate(" ", String.length(prefix)) <> line, color, color?)
    end)
  end

  defp diff_prefix(:del), do: "-  "
  defp diff_prefix(:ins), do: "+  "

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

    cond do
      count >= length ->
        {"", text}

      true ->
        keep = length - count
        {String.slice(text, 0, keep), String.slice(text, keep, count)}
    end
  end

  defp render_binaries(text) do
    text
    |> replace_printable_binaries()
    |> stringify_bit_specs()
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

  defp colorize(text, _color, false), do: text
  defp colorize(text, nil, _color?), do: text

  defp colorize(text, color, true) do
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

        String.starts_with?(content, "%{") and String.ends_with?(content, "}") ->
          format_map_lines(content)

        true ->
          [content]
      end

    reattach_ansi(lines, prefix, suffix)
  end

  defp format_map_lines(map_text, level \\ 0) do
    inner =
      map_text
      |> String.trim_leading("%{")
      |> String.trim_trailing("}")
      |> String.trim()

    entries = split_map_entries(inner)

    if length(entries) <= 1 do
      [String.duplicate("  ", level) <> map_text]
    else
      indent = String.duplicate("  ", level)
      last_index = length(entries) - 1

      formatted =
        entries
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, idx} ->
          suffix = if idx < last_index, do: ",", else: ""
          format_map_entry(entry, level + 1, suffix)
        end)

      [indent <> "%{"] ++ formatted ++ [indent <> "}"]
    end
  end

  defp format_map_entry(entry, level, suffix) do
    indent = String.duplicate("  ", level)
    trimmed = String.trim(entry)

    case split_key_value(trimmed) do
      {key, value} when is_binary(value) ->
        value_trimmed = String.trim_leading(value)

        if String.starts_with?(value_trimmed, "%{") do
          formatted = format_map_lines(value_trimmed, level + 1)
          [head | tail] = formatted
          head_line = indent <> key <> " => " <> String.trim_leading(head)

          lines =
            if tail == [] do
              [head_line]
            else
              [head_line | tail]
            end

          attach_suffix(lines, suffix)
        else
          [indent <> trimmed <> suffix]
        end

      _ ->
        [indent <> trimmed <> suffix]
    end
  end

  defp split_map_entries(inner) do
    inner
    |> do_split_entries([], "", %{brace: 0, bracket: 0, paren: 0, bit: 0})
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

  defp do_split_entries(<<>>, acc, current, _depth) do
    entry = String.trim(current)
    entries = if entry == "", do: acc, else: [entry | acc]
    Enum.reverse(entries)
  end

  defp do_split_entries(<<"\e[", rest::binary>>, acc, current, depth) do
    {sequence, remaining} = consume_ansi_sequence(rest, "")
    do_split_entries(remaining, acc, current <> "\e[" <> sequence, depth)
  end

  defp do_split_entries(<<?,, rest::binary>>, acc, current, depth) do
    if top_level?(depth) do
      entry = String.trim(current)
      new_acc = if entry == "", do: acc, else: [entry | acc]
      do_split_entries(rest, new_acc, "", depth)
    else
      do_split_entries(rest, acc, current <> ",", depth)
    end
  end

  defp do_split_entries(<<?<, ?<, rest::binary>>, acc, current, depth) do
    do_split_entries(rest, acc, current <> "<<", %{depth | bit: depth.bit + 1})
  end

  defp do_split_entries(<<?>, ?>, rest::binary>>, acc, current, %{bit: bit} = depth) when bit > 0 do
    do_split_entries(rest, acc, current <> ">>", %{depth | bit: bit - 1})
  end

  defp do_split_entries(<<char, rest::binary>>, acc, current, depth) do
    depth =
      case char do
        ?{ -> %{depth | brace: depth.brace + 1}
        ?} when depth.brace > 0 -> %{depth | brace: depth.brace - 1}
        ?[ -> %{depth | bracket: depth.bracket + 1}
        ?] when depth.bracket > 0 -> %{depth | bracket: depth.bracket - 1}
        ?( -> %{depth | paren: depth.paren + 1}
        ?) when depth.paren > 0 -> %{depth | paren: depth.paren - 1}
        _ -> depth
      end

    do_split_entries(rest, acc, current <> <<char>>, depth)
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

  defp consume_ansi_sequence(<<>>, acc), do: {acc, ""}

  defp consume_ansi_sequence(<<char, rest::binary>>, acc) do
    acc = acc <> <<char>>

    if char == ?m do
      {acc, rest}
    else
      consume_ansi_sequence(rest, acc)
    end
  end

  defp top_level?(%{brace: 0, bracket: 0, paren: 0, bit: 0}), do: true
  defp top_level?(_), do: false

  defp wraps_in_parens?(text) do
    String.starts_with?(text, "(") and String.ends_with?(text, ")") and byte_size(text) > 1
  end

  defp wrap_parentheses([]), do: []

  defp wrap_parentheses([single]), do: ["(" <> single <> ")"]

  defp wrap_parentheses(lines) do
    [first | rest] = lines
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

  defp reattach_ansi([], _prefix, _suffix), do: []

  defp reattach_ansi(lines, prefix, suffix) do
    case lines do
      [single] ->
        [prefix <> single <> suffix]

      _ ->
        [first | rest] = lines
        {middle, [last]} = Enum.split(rest, length(rest) - 1)
        [prefix <> first] ++ middle ++ [last <> suffix]
    end
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

end
