defmodule Assay.Formatter do
  @moduledoc false

  alias Assay.Formatter.Warning

  @doc """
  Formats decorated warnings into strings for the requested format.
  """
  @spec format([map()], atom(), keyword()) :: [String.t()]
  def format(entries, :text, opts) do
    project_root = Keyword.fetch!(opts, :project_root)

    Enum.map(entries, fn entry ->
      format_text_entry(entry, project_root, opts)
    end)
  end

  def format(entries, :elixir, opts) do
    format(entries, :text, Keyword.put(opts, :pretty_erlang, true))
  end

  def format(entries, :github, opts) do
    project_root = Keyword.fetch!(opts, :project_root)

    Enum.map(entries, fn entry ->
      path = entry.relative_path || relative_display(entry.path, project_root) || "unknown"
      line = entry.line || 0
      message = github_escape(entry.match_text || entry.text || "Dialyzer warning")
      "::warning file=#{path},line=#{line}::#{message}"
    end)
  end

  defp format_text_entry(entry, project_root, opts) do
    relative = entry.relative_path || relative_display(entry.path, project_root) || "nofile"
    warning =
      Warning.render(entry,
        relative_path: relative,
        color?: Keyword.get(opts, :color?, false)
      )
    location = format_location(relative, entry.line, entry.column)
    code_line = format_code_line(entry.code)
    snippet = format_snippet(entry.path, entry.line, entry.column)

    [
      "┌─ warning: #{location}",
      code_line,
      snippet || "│"
    ]
    |> Kernel.++(format_detail_lines(warning.details, opts))
    |> Kernel.++(["└─ #{warning.headline}"])
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_location(relative, line, column) do
    base = relative || "unknown"

    cond do
      line && column -> "#{base}:#{line}:#{column}"
      line -> "#{base}:#{line}"
      true -> base
    end
  end

  defp format_code_line(nil), do: nil

  defp format_code_line(code) do
    pretty =
      code
      |> Atom.to_string()
      |> String.trim_leading("warn_")
      |> String.replace("_", " ")

    "│   (#{pretty})"
  end

  defp format_snippet(nil, _line, _column), do: nil
  defp format_snippet(_path, nil, _column), do: nil

  defp format_snippet(path, line, column) do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path),
         source_line when is_binary(source_line) <- fetch_line(contents, line) do
      digits = line |> Integer.to_string() |> String.length()
      line_label = String.pad_leading(Integer.to_string(line), digits)
      sanitized = sanitize_line(source_line)

      pointer =
        case column do
          column when is_integer(column) and column > 0 ->
            indent = max(column - 1, 0)
            gutter = String.duplicate(" ", digits)
            "#{gutter} │ #{String.duplicate(" ", indent)}^"

          _ ->
            nil
        end

      snippet_lines = [
        "│",
        "#{line_label} │ #{sanitized}",
        pointer,
        "│"
      ]

      Enum.reject(snippet_lines, &is_nil/1)
    else
      _ -> nil
    end
  end

  defp fetch_line(contents, line) when line > 0 do
    contents
    |> String.split("\n", trim: false)
    |> Enum.at(line - 1)
  end

  defp fetch_line(_contents, _line), do: nil

  defp sanitize_line(nil), do: ""

  defp sanitize_line(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp format_detail_lines([], _opts), do: []

  defp format_detail_lines(details, opts) do
    pretty_erlang? = Keyword.get(opts, :pretty_erlang, false)

    details
    |> drop_leading_blank()
    |> maybe_pretty_erlang(pretty_erlang?)
    |> strip_common_indent()
    |> highlight_detail_lines()
    |> Enum.map(fn
      "" -> "│"
      line -> "│ " <> line
    end)
  end

  defp drop_leading_blank(["" | rest]), do: drop_leading_blank(rest)
  defp drop_leading_blank([]), do: []
  defp drop_leading_blank(lines), do: lines

  defp maybe_pretty_erlang(lines, true) do
    if Code.ensure_loaded?(Erlex) do
      convert_erlang_blocks(lines)
    else
      lines
    end
  end

  defp maybe_pretty_erlang(lines, _), do: lines

  defp convert_erlang_blocks(lines) do
    do_convert_erlang(lines, [])
  end

  defp do_convert_erlang([], acc), do: Enum.reverse(acc)

  defp do_convert_erlang([line | rest], acc) do
    trimmed = String.trim_leading(line)

    if erlang_block_start?(trimmed) do
      {chunk_lines, remaining} = take_block(rest, paren_delta(line), [line])
      converted = pretty_block(chunk_lines)
      do_convert_erlang(remaining, Enum.reverse(converted) ++ acc)
    else
      do_convert_erlang(rest, [line | acc])
    end
  end

  defp erlang_block_start?(line) do
    String.starts_with?(line, ["(", "\#{"])
  end

  defp take_block(rest, balance, acc) when balance <= 0 do
    {Enum.reverse(acc), rest}
  end

  defp take_block([], _balance, acc) do
    {Enum.reverse(acc), []}
  end

  defp take_block([line | tail], balance, acc) do
    delta = paren_delta(line)
    take_block(tail, balance + delta, [line | acc])
  end

  defp paren_delta(line) do
    line
    |> String.graphemes()
    |> Enum.reduce(0, fn
      "(", acc -> acc + 1
      ")", acc -> acc - 1
      _, acc -> acc
    end)
  end

  defp pretty_block(lines) do
    chunk =
      lines
      |> Enum.join("\n")
      |> String.trim()

    case run_erlex(chunk) do
      {:ok, pretty} ->
        pretty
        |> String.trim()
        |> String.split("\n")

      :error ->
        lines
    end
  end

  defp run_erlex(chunk) do
    if function_exported?(Erlex, :pretty_print, 1) do
      try do
        {:ok, Erlex.pretty_print(chunk)}
      rescue
        _ -> :error
      catch
        _, _ -> :error
      end
    else
      :error
    end
  end

  defp highlight_detail_lines(lines) do
    Enum.flat_map(lines, fn line ->
      if reason_line?(line) do
        {before, after_part} = split_on_phrase(line, "will never return")
        trimmed_before = String.trim_trailing(before || "")

        reason =
          ["will never return", after_part]
          |> Enum.join()
          |> String.trim()

        parts =
          []
          |> maybe_append(trimmed_before)
          |> Kernel.++(["-> " <> reason])

        parts
      else
        [line]
      end
    end)
  end

  defp maybe_append(list, ""), do: list
  defp maybe_append(list, item), do: list ++ [item]

  defp split_on_phrase(line, phrase) do
    case String.split(line, phrase, parts: 2) do
      [before, after_part] -> {before, after_part}
      _ -> {line, ""}
    end
  end

  defp reason_line?(line) do
    String.contains?(line, "will never return")
  end

  defp strip_common_indent(lines) do
    indent =
      lines
      |> Enum.filter(&(String.trim(&1) != ""))
      |> Enum.map(&leading_indent/1)
      |> case do
        [] -> 0
        counts -> Enum.min(counts)
      end

    if indent == 0 do
      lines
    else
      Enum.map(lines, fn
        "" -> ""
        line -> drop_indent(line, indent)
      end)
    end
  end

  defp drop_indent(line, indent) do
    trimmed = min(indent, byte_size(line))
    binary_part(line, trimmed, byte_size(line) - trimmed)
  end

  defp leading_indent(line), do: leading_indent(line, 0)

  defp leading_indent(<<char::utf8, rest::binary>>, acc) when char in [?\s, ?\t],
    do: leading_indent(rest, acc + 1)

  defp leading_indent(_rest, acc), do: acc

  defp relative_display(nil, _root), do: nil

  defp relative_display(path, root) do
    Path.relative_to(path, root)
  rescue
    _ -> path
  end

  defp github_escape(message) do
    message
    |> String.replace("%", "%25")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end
end
