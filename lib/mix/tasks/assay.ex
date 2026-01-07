defmodule Mix.Tasks.Assay do
  @moduledoc """
  Run incremental Dialyzer using the host project's mix.exs config.

  ## Options

  * `--print-config` - Print the effective Dialyzer configuration
  * `--format FORMAT` / `-f FORMAT` - Output format (text, elixir, github, json, sarif, llm)
    * Can be specified multiple times to output multiple formats
  * `--apps APP1,APP2` - Override apps list (comma-separated)
  * `--warning-apps APP1,APP2` - Override warning_apps list (comma-separated)
  * `--dialyzer-flag FLAG` - Pass additional Dialyzer flags
  * `--ignore-file PATH` - Override ignore file path (default: `dialyzer_ignore.exs`)
  * `--explain-ignores` - Show detailed information about which warnings were ignored and which rules matched them

  ## Exit Codes

  * `0` - Clean (no warnings after ignores)
  * `1` - Warnings detected
  * `2` - Error occurred

  ## Examples

      mix assay
      mix assay --print-config
      mix assay --format github --format sarif
      mix assay --apps my_app,my_dep
      mix assay --dialyzer-flag="--statistics"
      mix assay --ignore-file="custom_ignore.exs"
      mix assay --explain-ignores
  """
  use Mix.Task

  @shortdoc "Run incremental Dialyzer using the host project's mix.exs config"

  @impl true
  def run(args) do
    opts = parse_args(args)

    case Assay.run(opts) do
      :ok ->
        :ok

      :warnings ->
        Mix.shell().info("Dialyzer reported warnings")
        exit({:shutdown, 1})
    end
  end

  defp parse_args(args) do
    {raw_flag_values, remaining_args} = extract_dialyzer_flags(args)

    {opts, argv, invalid} =
      OptionParser.parse(remaining_args,
        strict: [
          print_config: :boolean,
          format: :string,
          apps: :string,
          warning_apps: :string,
          ignore_file: :string,
          explain_ignores: :boolean
        ],
        aliases: [f: :format]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    formats =
      opts
      |> Keyword.get_values(:format)
      |> Enum.map(&format_atom/1)

    normalized_formats =
      formats
      |> case do
        [] -> [:text]
        list -> list
      end

    apps_override = parse_app_option(Keyword.get_values(opts, :apps))
    warning_override = parse_app_option(Keyword.get_values(opts, :warning_apps))

    flag_overrides = if raw_flag_values == [], do: nil, else: raw_flag_values

    cli_opts =
      []
      |> Keyword.put(:print_config, Keyword.get(opts, :print_config, false))
      |> Keyword.put(:formats, normalized_formats)
      |> Keyword.put(:explain_ignores, Keyword.get(opts, :explain_ignores, false))
      |> maybe_put(:apps, apps_override)
      |> maybe_put(:warning_apps, warning_override)
      |> maybe_put(:dialyzer_flags, flag_overrides)
      |> maybe_put(:ignore_file, Keyword.get(opts, :ignore_file))

    if argv != [] do
      Mix.raise("Unexpected arguments: #{Enum.join(argv, ", ")}")
    end

    cli_opts
  end

  defp format_atom(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.to_atom()
    |> validate_format()
  end

  defp format_atom(value) when is_atom(value) do
    validate_format(value)
  end

  defp format_atom(value) do
    Mix.raise("Unknown format: #{inspect(value)}")
  end

  defp validate_format(format) when format in [:text, :elixir, :github, :llm, :sarif, :json],
    do: format

  defp validate_format(format) do
    Mix.raise(
      "Unsupported format #{inspect(format)}. Supported formats: text, elixir, github, llm, sarif, json."
    )
  end

  defp parse_app_option([]), do: nil

  defp parse_app_option(values) do
    values
    |> Enum.flat_map(fn value ->
      value
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp extract_dialyzer_flags(args), do: do_extract_flags(args, [], [])

  defp do_extract_flags([], flags, rest), do: {Enum.reverse(flags), Enum.reverse(rest)}

  defp do_extract_flags(["--dialyzer-flag=" <> value | tail], flags, rest),
    do: do_extract_flags(tail, [value | flags], rest)

  defp do_extract_flags(["--dialyzer-flag", value | tail], flags, rest),
    do: do_extract_flags(tail, [value | flags], rest)

  defp do_extract_flags(["--dialyzer-flag"], _flags, _rest) do
    Mix.raise("--dialyzer-flag expects a value (try --dialyzer-flag=\"--statistics\")")
  end

  defp do_extract_flags([arg | tail], flags, rest),
    do: do_extract_flags(tail, flags, [arg | rest])
end
