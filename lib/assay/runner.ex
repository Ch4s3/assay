defmodule Assay.Runner do
  @moduledoc """
  Executes incremental Dialyzer runs directly via `:dialyzer.run/1`.
  """

  alias Assay.Config
  alias Assay.Ignore
  alias Assay.Formatter

  @type run_result :: :ok | :warnings

  @spec run(Config.t(), keyword()) :: run_result
  def run(%Config{} = config, opts \\ []) do
    quiet? = Keyword.get(opts, :quiet, false)

    unless quiet? do
      Mix.shell().info("""
      Assay (incremental dialyzer)
        apps: #{inspect(config.apps)}
        warning_apps: #{inspect(config.warning_apps)}
        plt: #{config.plt_path}
        ignore_file: #{ignore_description(config)}
      """)
    end

    result = analyze(config, opts)

    unless quiet? do
      log_ignored(result.ignored, result.ignore_path, config.project_root)
    end

    formats = opts[:formats] || [:text]

    Enum.each(formats, fn format ->
      formatter_opts = [
        project_root: config.project_root,
        pretty_erlang: format == :elixir,
        color?: color_enabled?(format)
      ]

      Formatter.format(result.warnings, format, formatter_opts)
      |> Enum.each(&IO.puts/1)
    end)

    result.status
  end

  @doc """
  Runs incremental Dialyzer and returns structured diagnostics without printing.
  """
  @spec analyze(Config.t(), keyword()) ::
          %{
            status: run_result,
            warnings: [Ignore.entry()],
            ignored: [Ignore.entry()],
            ignore_path: binary() | nil,
            options: keyword()
          }
  def analyze(%Config{} = config, opts \\ []) do
    Mix.Task.run("compile")
    File.mkdir_p!(config.cache_dir)

    options = dialyzer_options(config)

    maybe_print_config(opts, config, options)

    warnings = run_dialyzer(options)

    entries = Ignore.decorate(warnings, config.project_root)
    {visible, ignored, ignore_path} = Ignore.filter(entries, config.ignore_file)
    status = if visible == [], do: :ok, else: :warnings

    %{
      status: status,
      warnings: visible,
      ignored: ignored,
      ignore_path: ignore_path,
      options: options
    }
  end

  @doc false
  @spec dialyzer_options(Config.t()) :: keyword()
  def dialyzer_options(%Config{} = config) do
    plt = String.to_charlist(config.plt_path)

    base_opts = [
      {:analysis_type, :incremental},
      {:check_plt, false},
      {:from, :byte_code},
      {:get_warnings, true},
      {:report_mode, :quiet},
      {:plts, [plt]},
      {:output_plt, plt},
      {:files_rec, charlist_paths(config, config.apps)},
      {:warning_files_rec, charlist_paths(config, config.warning_apps)}
    ]

    case config.warnings do
      [] -> base_opts
      warnings -> base_opts ++ [{:warnings, warnings}]
    end
  end

  defp charlist_paths(config, apps) do
    apps
    |> Enum.map(&format_app(&1, config))
    |> Enum.map(&String.to_charlist/1)
  end

  defp run_dialyzer(opts) do
    try do
      apply(dialyzer_runner(), :run, [opts])
    catch
      {:dialyzer_error, msg} ->
        raise Mix.Error, IO.iodata_to_binary(msg)
    end
  end

  defp format_app(app, config) when is_atom(app) do
    case :code.lib_dir(app) do
      {:error, _} -> project_app_path(app, config)
      path -> Path.join(IO.chardata_to_string(path), "ebin")
    end
  end

  defp format_app(path, config) when is_binary(path) do
    expand_path(path, config.project_root)
  end

  defp format_app(path, config) when is_list(path) do
    path
    |> IO.chardata_to_string()
    |> format_app(config)
  end

  defp format_app(other, _config) do
    raise Mix.Error, "Invalid app identifier: #{inspect(other)}"
  end

  defp color_enabled?(:elixir) do
    case System.get_env("MIX_ANSI_ENABLED") do
      "false" -> false
      _ -> true
    end
  end

  defp color_enabled?(_), do: false

  defp project_app_path(app, %Config{build_lib_path: build_lib_path, project_root: root}) do
    candidate =
      [build_lib_path, Atom.to_string(app), "ebin"]
      |> Path.join()
      |> expand_path(root)

    if File.dir?(candidate) do
      candidate
    else
      raise Mix.Error,
            "Assay could not locate the #{app} ebin under #{build_lib_path}; " <>
              "ensure the project is compiled and listed in mix.exs"
    end
  end

  defp expand_path(path, base) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.expand(path, base)
    end
  end

  defp log_ignored([], _path, _root), do: :ok

  defp log_ignored(ignored, path, root) do
    count = length(ignored)

    Mix.shell().info(
      "Ignored #{count} warning#{plural_suffix(count)} via #{relative_display(path, root)}"
    )
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_), do: "s"

  defp relative_display(nil, _root), do: "dialyzer_ignore.exs"

  defp relative_display(path, root) do
    case Path.relative_to(path, root) do
      relative when relative != path -> relative
      _ -> path
    end
  rescue
    _ -> path
  end

  defp ignore_description(%Config{ignore_file: nil}), do: "none"

  defp ignore_description(%Config{ignore_file: path, project_root: root}) do
    description = relative_display(path, root)

    if File.exists?(path) do
      description
    else
      "#{description} (missing)"
    end
  end

  defp maybe_print_config(opts, config, options) do
    if Keyword.get(opts, :print_config, false) do
      config_snapshot = %{
        project_root: config.project_root,
        apps: config.apps,
        warning_apps: config.warning_apps,
        cache_dir: config.cache_dir,
        plt_path: config.plt_path,
        ignore_file: config.ignore_file
      }

      printable = inspect(options, limit: :infinity, pretty: true, charlists: :as_lists)

      Mix.shell().info("""
      Assay configuration (from mix.exs):
      #{inspect(config_snapshot, pretty: true, limit: :infinity)}

      Effective Dialyzer options:
      #{printable}
      """)
    end
  end

  defp dialyzer_runner do
    Application.get_env(:assay, :dialyzer_runner_module, :dialyzer)
  end
end
