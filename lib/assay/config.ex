defmodule Assay.Config do
  @moduledoc """
  Minimal configuration loader backed directly by `Mix.Project.config/0`.

  The first milestone keeps all user-facing knobs inside the host project's
  `mix.exs`. This module extracts that data and normalizes derived paths so the
  runner can work with a single struct.
  """

  @enforce_keys [
    :apps,
    :warning_apps,
    :project_root,
    :cache_dir,
    :plt_path,
    :build_lib_path,
    :elixir_lib_path,
    :ignore_file
  ]
  defstruct @enforce_keys ++ [warnings: []]

  @optional_apps [
    {:erlex, :"Elixir.Erlex"},
    {:igniter, :"Elixir.Igniter"},
    {:rewrite, :"Elixir.Rewrite.Source"}
  ]

  @type t :: %__MODULE__{
          apps: [atom()],
          warning_apps: [atom()],
          project_root: binary(),
          cache_dir: binary(),
          plt_path: binary(),
          build_lib_path: binary(),
          elixir_lib_path: binary(),
          ignore_file: binary() | nil,
          warnings: [atom()]
        }

  @doc """
  Reads the host project's `:assay` configuration and returns a struct that the
  rest of the system can consume.

  Options allow tests or future callers to override derived paths (e.g. when the
  runner eventually supports daemons or alternate cache directories).
  """
  @spec from_mix_project(keyword()) :: t()
  def from_mix_project(opts \\ []) do
    project_config = Mix.Project.config()

    dialyzer_config =
      project_config
      |> Keyword.get(:assay, [])
      |> Keyword.get(:dialyzer, [])

    apps =
      dialyzer_config
      |> fetch_list!(:apps)
      |> include_optional_apps()

    warning_apps = fetch_list!(dialyzer_config, :warning_apps)

    project_root = Keyword.get(opts, :project_root, File.cwd!())
    cache_dir = Keyword.get(opts, :cache_dir, Path.join(project_root, "_build/assay"))
    plt_path = Keyword.get(opts, :plt_path, default_plt_path(cache_dir))
    build_lib_path = Keyword.get(opts, :build_lib_path, default_build_lib_path(project_root))
    elixir_lib_path = Keyword.get(opts, :elixir_lib_path, default_elixir_lib_path())
    ignore_file = Keyword.get(dialyzer_config, :ignore_file, "dialyzer_ignore.exs")
    warnings = list_option(dialyzer_config, :warnings, [])
    normalized_ignore = normalize_ignore_file(ignore_file, project_root)

    %__MODULE__{
      apps: apps,
      warning_apps: warning_apps,
      project_root: project_root,
      cache_dir: cache_dir,
      plt_path: plt_path,
      build_lib_path: build_lib_path,
      elixir_lib_path: elixir_lib_path,
      ignore_file: normalized_ignore,
      warnings: warnings
    }
  end

  defp fetch_list!(config, key) do
    value = Keyword.fetch!(config, key)

    case value do
      list when is_list(list) -> list
      other -> raise_invalid_value(key, other)
    end
  rescue
    KeyError ->
      message =
        "Assay expects :#{key} to be present under :assay, dialyzer: [...] in mix.exs"

      reraise Mix.Error, [message: message], __STACKTRACE__
  end

  defp raise_invalid_value(key, value) do
    raise Mix.Error,
          "Assay expects :#{key} to be a list (got: #{inspect(value)})"
  end

  defp default_build_lib_path(project_root) do
    env_segment = Atom.to_string(Mix.env())
    Path.join([project_root, "_build", env_segment, "lib"])
  end

  defp default_elixir_lib_path do
    :code.lib_dir(:elixir)
    |> to_string()
  end

  defp default_plt_path(cache_dir) do
    Path.join(cache_dir, plt_filename())
  end

  @doc false
  def plt_filename do
    "assay-elixir_#{System.version()}-otp_#{System.otp_release()}.incremental.plt"
  end

  defp include_optional_apps(apps) do
    optional =
      for {app, module} <- @optional_apps, Code.ensure_loaded?(module), do: app

    Enum.uniq(apps ++ optional)
  end

  defp normalize_ignore_file(value, _project_root) when value in [nil, false], do: nil

  defp normalize_ignore_file(value, project_root) do
    value
    |> to_string()
    |> Path.expand(project_root)
  end

  defp list_option(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_list(value) -> value
      other -> raise_invalid_value(key, other)
    end
  end
end
