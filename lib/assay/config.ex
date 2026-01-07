defmodule Assay.Config do
  @moduledoc """
  Minimal configuration loader backed directly by `Mix.Project.config/0`.

  The first milestone keeps all user-facing knobs inside the host project's
  `mix.exs`. This module extracts that data and normalizes derived paths so the
  runner can work with a single struct.

  ## Example Configuration

  ```elixir
  # In mix.exs
  def project do
    [
      app: :my_app,
      assay: [
        dialyzer: [
          apps: [:my_app, :my_dep],
          warning_apps: [:my_app],
          ignore_file: "dialyzer_ignore.exs",
          dialyzer_flags: ["--statistics"]
        ]
      ]
    ]
  end
  ```

  The `apps` list determines which applications are included in the PLT analysis.
  The `warning_apps` list determines which applications generate warnings (typically
  just your project apps, not dependencies).

  Use `mix assay.install` to automatically configure these settings.
  """

  alias Assay.DialyzerFlags

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
  defstruct @enforce_keys ++
              [
                warnings: [],
                app_sources: [],
                warning_app_sources: [],
                discovery_info: %{},
                dialyzer_flags: [],
                dialyzer_flag_options: [],
                dialyzer_init_plt: nil,
                dialyzer_output_plt: nil
              ]

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
          warnings: [atom()],
          app_sources: list(),
          warning_app_sources: list(),
          discovery_info: map(),
          dialyzer_flags: term(),
          dialyzer_flag_options: keyword(),
          dialyzer_init_plt: binary() | nil,
          dialyzer_output_plt: binary() | nil
        }

  @doc """
  Reads the host project's `:assay` configuration and returns a struct that the
  rest of the system can consume.

  Options allow tests or future callers to override derived paths (e.g. when the
  runner eventually supports daemons or alternate cache directories).

  ## Options

  * `:project_root` - Override project root (defaults to `File.cwd!()`)
  * `:cache_dir` - Override cache directory
  * `:plt_path` - Override PLT path
  * `:build_lib_path` - Override build lib path
  * `:dependency_apps` - Override dependency apps list

  ## Examples

      # Load from mix.exs
      config = Assay.Config.from_mix_project()
      config.apps
      # => [:my_app, :my_dep, ...]
      config.warning_apps
      # => [:my_app]

      # Override project root for testing
      config = Assay.Config.from_mix_project(project_root: "/tmp/test_project")
      config.project_root
      # => "/tmp/test_project"

      # Override cache directory
      config = Assay.Config.from_mix_project(cache_dir: "/tmp/assay_cache")
      config.cache_dir
      # => "/tmp/assay_cache"
  """
  @spec from_mix_project(keyword()) :: t()
  def from_mix_project(opts \\ []) do
    project_config = Mix.Project.config()

    dialyzer_config =
      project_config
      |> Keyword.get(:assay, [])
      |> Keyword.get(:dialyzer, [])

    project_root = Keyword.get(opts, :project_root, File.cwd!())
    cache_dir = Keyword.get(opts, :cache_dir, Path.join(project_root, "_build/assay"))
    plt_path = Keyword.get(opts, :plt_path, default_plt_path(cache_dir))
    build_lib_path = Keyword.get(opts, :build_lib_path, default_build_lib_path(project_root))
    elixir_lib_path = Keyword.get(opts, :elixir_lib_path, default_elixir_lib_path())

    context =
      build_context(project_config,
        dependency_apps: Keyword.get(opts, :dependency_apps),
        build_lib_path: build_lib_path
      )

    raw_apps = list_override(opts, dialyzer_config, :apps)
    raw_warning_apps = list_override(opts, dialyzer_config, :warning_apps)

    # Support both :dialyzer_flags and :flags (for convenience)
    dialyzer_flags_value = Keyword.get(dialyzer_config, :dialyzer_flags, [])
    flags_value = Keyword.get(dialyzer_config, :flags, [])

    # Normalize both separately, then combine
    normalized_dialyzer_flags = normalize_flag_list(dialyzer_flags_value || [])
    normalized_flags = normalize_flag_list(flags_value || [])

    raw_config_flags = normalized_dialyzer_flags ++ normalized_flags
    cli_flag_list = normalize_flag_list(Keyword.get(opts, :dialyzer_flags, []))

    {apps_base, app_sources} = resolve_app_selectors(raw_apps, context)
    {warning_apps, warning_sources} = resolve_app_selectors(raw_warning_apps, context)

    apps = include_optional_apps(apps_base)

    # Support both :ignore_file and :ignore_warnings (for convenience)
    ignore_file =
      cond do
        Keyword.has_key?(opts, :ignore_file) ->
          Keyword.get(opts, :ignore_file)

        Keyword.has_key?(dialyzer_config, :ignore_file) ->
          Keyword.get(dialyzer_config, :ignore_file)

        Keyword.has_key?(dialyzer_config, :ignore_warnings) ->
          Keyword.get(dialyzer_config, :ignore_warnings)

        true ->
          "dialyzer_ignore.exs"
      end

    warnings = list_option(dialyzer_config, :warnings, [])
    normalized_ignore = normalize_ignore_file(ignore_file, project_root)

    config_flag_info = DialyzerFlags.parse(raw_config_flags, :config, project_root)
    cli_flag_info = DialyzerFlags.parse(cli_flag_list, :cli, project_root)

    dialyzer_flags = raw_config_flags ++ cli_flag_list

    dialyzer_flag_options = config_flag_info.options ++ cli_flag_info.options

    dialyzer_init_plt =
      cli_flag_info.init_plt ||
        config_flag_info.init_plt
        |> maybe_charlist_to_string()

    dialyzer_output_plt =
      cli_flag_info.output_plt ||
        config_flag_info.output_plt
        |> maybe_charlist_to_string()

    %__MODULE__{
      apps: apps,
      warning_apps: warning_apps,
      project_root: project_root,
      cache_dir: cache_dir,
      plt_path: plt_path,
      build_lib_path: build_lib_path,
      elixir_lib_path: elixir_lib_path,
      ignore_file: normalized_ignore,
      warnings: warnings,
      app_sources: app_sources,
      warning_app_sources: warning_sources,
      dialyzer_flags: dialyzer_flags,
      dialyzer_flag_options: dialyzer_flag_options,
      dialyzer_init_plt: dialyzer_init_plt,
      dialyzer_output_plt: dialyzer_output_plt,
      discovery_info: %{
        project_apps: context.project_apps,
        dependency_apps: context.dependency_apps,
        base_apps: context.base_apps
      }
    }
  end

  defp fetch_list!(config, key) do
    value = Keyword.fetch!(config, key)

    case value do
      list when is_list(list) -> list
      # Allow single atom selectors
      atom when is_atom(atom) -> [atom]
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

  defp list_override(opts, dialyzer_config, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> to_list(value)
      :error -> fetch_list!(dialyzer_config, key)
    end
  end

  defp to_list(value) when is_list(value), do: value
  defp to_list(value), do: [value]

  defp build_context(project_config, opts) do
    project_apps = project_apps(project_config)

    dependency_apps =
      case Keyword.get(opts, :dependency_apps) do
        nil -> default_dependency_apps(project_apps)
        apps -> apps
      end

    dependency_apps_list = if dependency_apps, do: dependency_apps, else: []

    %{
      project_apps: project_apps,
      current_app: current_app(project_config, project_apps),
      dependency_apps: dependency_apps_list,
      base_apps: base_apps()
    }
  end

  defp project_apps(_project_config) do
    case Mix.Project.apps_paths() do
      paths when is_map(paths) ->
        paths
        |> Map.keys()
        |> Enum.sort()

      _ ->
        app = Mix.Project.config()[:app]
        app |> List.wrap() |> Enum.reject(&is_nil/1)
    end
  end

  defp current_app(project_config, project_apps) do
    cond do
      app = project_config[:app] -> app
      project_apps != [] -> hd(project_apps)
      true -> nil
    end
  end

  defp default_dependency_apps(project_apps) do
    Mix.Dep.cached()
    |> Enum.map(& &1.app)
    |> Enum.reject(&(&1 in project_apps))
  rescue
    _ -> []
  end

  defp base_apps do
    [:logger, :kernel, :stdlib, :elixir, :erts]
  end

  defp resolve_app_selectors(values, context) do
    values
    |> Enum.reduce({[], []}, fn value, {acc, meta} ->
      case expand_selector(value, context) do
        {:selector, label, apps} ->
          {acc ++ apps, meta ++ [%{selector: label, apps: apps}]}

        {:literal, app} ->
          {acc ++ [app], meta}
      end
    end)
    |> then(fn {apps, meta} -> {Enum.uniq(apps), meta} end)
  end

  defp expand_selector(value, context) do
    case normalize_selector(value) do
      {:selector, :project} -> expand_project_selector(context)
      {:selector, :project_plus_deps} -> expand_project_plus_deps_selector(context)
      {:selector, :current} -> expand_current_selector(context)
      {:selector, :current_plus_deps} -> expand_current_plus_deps_selector(context)
      {:literal, literal} -> {:literal, literal}
    end
  end

  defp expand_project_selector(context) do
    apps = Map.get(context, :project_apps, [])
    ensure_apps!(apps, :project)
    {:selector, :project, apps}
  end

  defp expand_project_plus_deps_selector(context) do
    project_apps = Map.get(context, :project_apps, [])
    dependency_apps = Map.get(context, :dependency_apps, [])
    base_apps = Map.get(context, :base_apps, [])
    apps = Enum.uniq(project_apps ++ dependency_apps ++ base_apps)
    ensure_apps!(apps, :project_plus_deps)
    {:selector, :project_plus_deps, apps}
  end

  defp expand_current_selector(context) do
    case context.current_app do
      nil -> raise Mix.Error, "Unable to resolve current app selector (no :app in mix.exs)"
      app -> {:selector, :current, [app]}
    end
  end

  defp expand_current_plus_deps_selector(context) do
    case context.current_app do
      nil ->
        raise Mix.Error, "Unable to resolve current+deps selector (no :app in mix.exs)"

      app ->
        dependency_apps = Map.get(context, :dependency_apps, [])
        base_apps = Map.get(context, :base_apps, [])
        apps = Enum.uniq([app | dependency_apps] ++ base_apps)
        {:selector, :current_plus_deps, apps}
    end
  end

  defp ensure_apps!([], selector) do
    raise Mix.Error, "Selector #{selector} resolved to an empty list of applications"
  end

  defp ensure_apps!(_, _), do: :ok

  defp normalize_selector(value) when is_list(value) do
    value
    |> List.to_string()
    |> normalize_selector()
  end

  defp normalize_selector(value) when is_binary(value) do
    trimmed = String.trim(value)
    downcased = String.downcase(trimmed)

    cond do
      downcased in ["project", "project_apps"] -> {:selector, :project}
      downcased in ["project+deps", "project_plus_deps"] -> {:selector, :project_plus_deps}
      downcased == "current" -> {:selector, :current}
      downcased in ["current+deps", "current_plus_deps"] -> {:selector, :current_plus_deps}
      true -> {:literal, literal_app(trimmed)}
    end
  end

  defp normalize_selector(value) when is_atom(value) do
    case value do
      :project -> {:selector, :project}
      :project_plus_deps -> {:selector, :project_plus_deps}
      :"project+deps" -> {:selector, :project_plus_deps}
      :current -> {:selector, :current}
      :current_plus_deps -> {:selector, :current_plus_deps}
      :"current+deps" -> {:selector, :current_plus_deps}
      other -> {:literal, other}
    end
  end

  defp normalize_selector(value), do: {:literal, literal_app(value)}

  defp literal_app(value) when is_atom(value), do: value

  defp literal_app(value) when is_binary(value) do
    if String.contains?(value, "/") or String.contains?(value, "\\") do
      value
    else
      String.to_atom(value)
    end
  end

  defp literal_app(value) when is_list(value), do: List.to_string(value)

  defp literal_app(value), do: value

  defp normalize_flag_list(value) when is_list(value), do: value
  defp normalize_flag_list(nil), do: []
  defp normalize_flag_list(value), do: [value]

  defp maybe_charlist_to_string(nil), do: nil
  defp maybe_charlist_to_string(value), do: to_string(value)
end
