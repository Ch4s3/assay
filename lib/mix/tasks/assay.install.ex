defmodule Mix.Tasks.Assay.Install do
  @moduledoc false

  if Code.ensure_loaded?(Igniter.Mix.Task) do
    use Igniter.Mix.Task

    alias Igniter.Code.Keyword, as: CodeKeyword
    alias Igniter.Project.{Deps, MixProject}
    alias Rewrite.Source, as: Source

    @shortdoc "Install Assay and configure a project via Igniter"
    @assay_version Mix.Project.config()[:version] || "0.1.0"

    @impl Igniter.Mix.Task
    def supports_umbrella?, do: true

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :assay,
        adds_deps: [],
        installs: [],
        positional: [],
        composes: [],
        schema: [yes: :boolean, all_apps: :boolean],
        defaults: [],
        aliases: [A: :all_apps],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    @assign_detected_config :assay_detected_apps

    def igniter(igniter) do
      detected = Map.get(igniter.assigns, @assign_detected_config, detect_apps())
      selection = select_apps(igniter, detected)

      igniter
      |> ensure_assay_dep()
      |> ensure_project_config(selection)
      |> ensure_gitignore()
      |> ensure_ignore_file()
      |> Igniter.add_notice(summary(selection))
    end

    defp ensure_assay_dep(igniter) do
      igniter
      |> Igniter.include_existing_file("mix.exs", required?: true)
      |> Deps.add_dep(
        {:assay, "~> #{version_requirement(@assay_version)}",
         runtime: false, only: [:dev, :test]},
        on_exists: :skip
      )
    end

    defp ensure_project_config(igniter, %{apps: apps, warning_apps: warning_apps}) do
      dialyzer_ast =
        quote do
          [
            apps: unquote(apps),
            warning_apps: unquote(warning_apps)
          ]
        end

      default_ast =
        quote do
          [
            dialyzer: unquote(dialyzer_ast)
          ]
        end

      MixProject.update(igniter, :project, [:assay], fn
        nil ->
          {:ok, {:code, default_ast}}

        %{node: _} = zipper ->
          set_dialyzer_config(zipper, dialyzer_ast)

        _other ->
          {:warning,
           "Existing :assay configuration could not be updated automatically. Remove it or update it manually before re-running mix assay.install."}
      end)
    end

    defp ensure_gitignore(igniter) do
      entry = "_build/assay"

      Igniter.create_or_update_file(igniter, ".gitignore", entry <> "\n", fn source ->
        Source.update(source, :content, &append_gitignore_entry(&1, entry))
      end)
    end

    defp ensure_ignore_file(igniter) do
      Igniter.include_or_create_file(igniter, "dialyzer_ignore.exs", """
      [
        # Strings, regexes, or maps like:
        # %{file: "lib/my_app.ex", message: "unknown function"}
      ]
      """)
    end

    defp detect_apps do
      project_apps =
        Mix.Project.apps_paths()
        |> case do
          nil ->
            [Mix.Project.config()[:app]]

          paths ->
            paths
            |> Map.keys()
            |> Enum.sort()
        end
        |> Enum.reject(&is_nil/1)

      dep_apps =
        Mix.Dep.cached()
        |> Enum.map(& &1.app)
        |> Enum.reject(&(&1 in project_apps))

      base_apps = [:logger, :kernel, :stdlib, :elixir, :erts]

      apps =
        project_apps
        |> Enum.concat(dep_apps)
        |> Enum.concat(base_apps)
        |> Enum.uniq()

      %{project_apps: project_apps, all_apps: apps}
    end

    defp select_apps(igniter, %{project_apps: project_apps, all_apps: all_apps}) do
      warning_apps =
        project_apps
        |> fallback_project_apps()
        |> case do
          [] -> fallback_project_apps(all_apps)
          value -> value
        end

      extra_apps = all_apps -- warning_apps

      apps =
        if include_extra_apps?(igniter, warning_apps, extra_apps) do
          all_apps
        else
          warning_apps
        end

      %{apps: apps, warning_apps: warning_apps}
    end

    defp fallback_project_apps([]),
      do: Mix.Project.config()[:app] |> List.wrap() |> Enum.reject(&is_nil/1)

    defp fallback_project_apps(apps) when is_list(apps), do: apps
    defp fallback_project_apps(_), do: []

    defp include_extra_apps?(_igniter, _warning_apps, []), do: false

    defp include_extra_apps?(igniter, warning_apps, extra_apps) do
      all_apps_pref = option_enabled?(igniter, :all_apps)

      cond do
        all_apps_pref == true ->
          true

        all_apps_pref == false ->
          false

        option_enabled?(igniter, :yes) ->
          true

        true ->
          prompt_extra_apps?(warning_apps, extra_apps)
      end
    end

    defp option_enabled?(%{args: %{options: options}}, key) when is_list(options) do
      Keyword.get(options, key)
    end

    defp option_enabled?(_igniter, _key), do: nil

    defp prompt_extra_apps?(warning_apps, extra_apps) do
      current_display = inspect(warning_apps)
      extra_display = inspect(extra_apps)

      prompt = """
      Detected additional apps #{extra_display}.
      Include them alongside #{current_display} in :apps?
      """

      confirm_default_no(prompt)
    end

    defp confirm_default_no(prompt) do
      question = prompt <> " [y/N]"

      case Mix.shell().prompt(question) do
        response when is_binary(response) ->
          String.trim(response) in ["y", "Y", "yes", "YES"]

        _ ->
          false
      end
    end

    defp append_gitignore_entry(content, entry) do
      entries =
        content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))

      if entry in entries do
        content
      else
        trimmed = String.trim_trailing(content)
        prefix = if trimmed == "", do: "", else: trimmed <> "\n"
        prefix <> entry <> "\n"
      end
    end

    defp set_dialyzer_config(zipper, dialyzer_ast) do
      CodeKeyword.put_in_keyword(zipper, [:dialyzer], dialyzer_ast)
    end

    defp summary(%{apps: apps, warning_apps: warning_apps}) do
      """
      Installed Assay with:
        apps: #{inspect(apps)}
        warning_apps: #{inspect(warning_apps)}
      """
    end

    defp version_requirement(version) do
      [major, minor | _] = String.split(version, ".")
      Enum.join([major, minor], ".")
    end
  else
    use Mix.Task

    @shortdoc "Install Assay via Igniter"

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("""
      mix assay.install requires the Igniter dependency.

      Add {:igniter, "~> 0.7", optional: false} to your deps (or run `mix igniter.install assay`) \
      before invoking this task.
      """)
    end
  end
end
