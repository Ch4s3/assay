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
        strict: [print_config: :boolean, format: :string],
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

    cli_opts = [
      print_config: Keyword.get(opts, :print_config, false),
      formats: normalized_formats
    ]

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

  defp validate_format(format) when format in [:text, :elixir, :github, :llm], do: format

  defp validate_format(format) do
    Mix.raise(
      "Unsupported format #{inspect(format)}. Supported formats: text, elixir, github, llm."
    )
  end
end
