defmodule Mix.Tasks.Assay do
  @moduledoc false
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
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [print_config: :boolean, format: :string, apps: :string, warning_apps: :string],
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

    cli_opts =
      []
      |> Keyword.put(:print_config, Keyword.get(opts, :print_config, false))
      |> Keyword.put(:formats, normalized_formats)
      |> maybe_put(:apps, apps_override)
      |> maybe_put(:warning_apps, warning_override)

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
end
