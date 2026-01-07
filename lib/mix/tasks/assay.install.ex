if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Assay.Install do
    @moduledoc """
    Installs and configures Assay in the current project.

    This task uses Igniter to automatically configure Assay in your project. It:
    * Adds Assay as a dev/test dependency
    * Configures `apps` and `warning_apps` in `mix.exs`
    * Creates a `.gitignore` entry for `_build/assay`
    * Creates a `dialyzer_ignore.exs` file
    * Optionally generates CI workflow files

    ## Options

    * `--yes` - Skip all prompts and use defaults
    * `--all-apps` / `-A` - Include all detected apps in analysis (not just project apps)
    * `--ci=PROVIDER` - Generate CI workflow (github, gitlab, or none)

    ## Examples

        mix assay.install
        mix assay.install --yes --all-apps
        mix assay.install --ci=github
        mix assay.install --ci=gitlab
        mix assay.install --ci=none
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Keyword, as: CodeKeyword
    alias Igniter.Project.{Deps, MixProject}
    alias Rewrite.Source, as: Source

    @shortdoc "Install Assay and configure a project via Igniter"
    @assay_version Mix.Project.config()[:version] || "0.3.0"

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
        schema: [yes: :boolean, all_apps: :boolean, ci: :string],
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

      ci_provider = ci_provider(igniter)

      igniter
      |> ensure_assay_dep()
      |> ensure_project_config(selection)
      |> ensure_gitignore()
      |> ensure_ignore_file()
      |> ensure_ci(ci_provider)
      |> Igniter.add_notice(summary(selection, ci_provider))
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

    defp ensure_ci(igniter, :none), do: igniter

    defp ensure_ci(igniter, :github) do
      content = github_workflow_content()

      igniter
      |> Igniter.create_or_update_file(".github/workflows/assay.yml", content, fn source ->
        Source.update(source, :content, fn _ -> content end)
      end)
    end

    defp ensure_ci(igniter, :gitlab) do
      content = gitlab_pipeline_content()

      Igniter.create_or_update_file(igniter, ".gitlab-ci.yml", content, fn source ->
        Source.update(source, :content, fn _ -> content end)
      end)
    end

    defp ci_provider(%{args: %{options: options}}) when is_list(options) do
      options
      |> Keyword.get(:ci)
      |> normalize_ci_option()
    end

    defp ci_provider(_igniter), do: :github

    defp normalize_ci_option(nil), do: :github

    defp normalize_ci_option(option) when is_atom(option) do
      case option do
        :github -> :github
        :gitlab -> :gitlab
        :none -> :none
        other -> raise ArgumentError, "Unsupported ci option: #{inspect(other)}"
      end
    end

    defp normalize_ci_option(option) when is_binary(option) do
      option
      |> String.downcase()
      |> case do
        "github" -> :github
        "gitlab" -> :gitlab
        "none" -> :none
        other -> raise ArgumentError, "Unsupported ci option: #{other}"
      end
    end

    defp normalize_ci_option(other) do
      raise ArgumentError, "Unsupported ci option: #{inspect(other)}"
    end

    defp github_workflow_content do
      elixir = System.version()
      otp = otp_version()

      """
      name: Assay

      on:
        push:
          branches: [\"main\"]
        pull_request:

      permissions:
        contents: read

      jobs:
        assay:
          runs-on: ubuntu-latest
          env:
            MIX_ENV: dev
          steps:
            - uses: actions/checkout@v4

            - name: Set up Elixir
              uses: erlef/setup-beam@v1
              with:
                elixir-version: '#{elixir}'
                otp-version: '#{otp}'

            - name: Cache deps
              uses: actions/cache@v4
              with:
                path: deps
                key: ${{ runner.os }}-mix-${{ env.MIX_ENV }}-${{ hashFiles('mix.lock') }}
                restore-keys: ${{ runner.os }}-mix-${{ env.MIX_ENV }}-

            - name: Cache _build
              uses: actions/cache@v4
              with:
                path: _build/${{ env.MIX_ENV }}
                key: ${{ runner.os }}-build-${{ env.MIX_ENV }}-${{ hashFiles('mix.lock') }}
                restore-keys: ${{ runner.os }}-build-${{ env.MIX_ENV }}-

            - name: Cache Dialyzer PLT
              uses: actions/cache@v4
              with:
                path: _build/assay
                key: ${{ runner.os }}-plt-#{otp}-#{elixir}-${{ hashFiles('mix.lock') }}
                restore-keys: |
                  ${{ runner.os }}-plt-#{otp}-#{elixir}-

            - run: mix deps.get
            - run: mix compile --warnings-as-errors
            - run: mix assay --format github --format sarif | tee assay.sarif

            - name: Upload SARIF report
              if: always()
              uses: github/codeql-action/upload-sarif@v3
              with:
                sarif_file: assay.sarif
      """
    end

    defp gitlab_pipeline_content do
      elixir = System.version()
      otp = otp_version()

      """
      image: hexpm/elixir:#{elixir}-erlang-#{otp}-ubuntu-jammy

      variables:
        MIX_ENV: \"dev\"

      cache:
        key: \"$CI_COMMIT_REF_SLUG\"
        paths:
          - deps/
          - _build/dev/
          - _build/assay/

      stages:
        - assay

      assay:
        stage: assay
        before_script:
          - mix local.hex --force
          - mix local.rebar --force
          - mix deps.get
          - mix compile --warnings-as-errors
        script:
          - mix assay --format github --format sarif | tee assay.sarif
        artifacts:
          when: always
          paths:
            - assay.sarif
      """
    end

    defp otp_version do
      :erlang.system_info(:otp_release)
      |> to_string()
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

    defp summary(%{apps: apps, warning_apps: warning_apps}, ci_provider) do
      ci_line =
        case ci_provider do
          :github -> "\n  CI workflow: .github/workflows/assay.yml"
          :gitlab -> "\n  CI workflow: .gitlab-ci.yml"
          :none -> "\n  CI workflow: skipped (pass --ci=github or --ci=gitlab to scaffold)"
        end

      """
      Installed Assay with:
        apps: #{inspect(apps)}
        warning_apps: #{inspect(warning_apps)}#{ci_line}
      """
    end

    defp version_requirement(version) do
      [major, minor | _] = String.split(version, ".")
      Enum.join([major, minor], ".")
    end
  end
else
  defmodule Mix.Tasks.Assay.Install do
    @moduledoc """
    Install Assay via Igniter.

    This module is only available when Igniter is not loaded. It provides
    a fallback implementation that instructs users to install Igniter.
    """

    use Mix.Task

    @shortdoc "Install Assay via Igniter"

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("""
      mix assay.install requires the Igniter dependency.

      Add {:igniter, "~> 0.6", optional: false} to your deps (or run `mix igniter.install assay`) \
      before invoking this task.
      """)
    end
  end
end
