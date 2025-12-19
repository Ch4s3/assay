defmodule Mix.Tasks.Assay.InstallTest do
  use ExUnit.Case, async: true

  alias Igniter.Mix.Task.Args
  alias Igniter.Test, as: IgniterTest

  @detected %{project_apps: [:demo], all_apps: [:demo, :logger]}

  setup_all do
    Application.ensure_all_started(:rewrite)
    :ok
  end

  test "installs dependency and configures mix project files" do
    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> put_option(:all_apps, false)
      |> Mix.Tasks.Assay.Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]

    mix_contents = Map.fetch!(files, "mix.exs")
    assert mix_contents =~ "assay: [dialyzer: [apps: [:demo], warning_apps: [:demo]]]"
    assert mix_contents =~ "{:assay, \"~> 0.1\", runtime: false, only: [:dev, :test]}"

    assert Map.fetch!(files, ".gitignore") == "_build/assay\n"

    assert Map.fetch!(files, "dialyzer_ignore.exs") =~
             "# %{file: \"lib/my_app.ex\", message: \"unknown function\"}"
  end

  test "installer can run at the root of umbrella projects" do
    assert Mix.Tasks.Assay.Install.supports_umbrella?()
  end

  test "can opt into including detected dependencies via flag" do
    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> put_option(:all_apps, true)
      |> Mix.Tasks.Assay.Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    mix_contents = Map.fetch!(files, "mix.exs")
    assert mix_contents =~ "assay: [dialyzer: [apps: [:demo, :logger], warning_apps: [:demo]]]"
  end

  defp mixfile do
    """
    defmodule Demo.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo,
          version: "0.1.0",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        []
      end
    end
    """
  end

  defp put_option(igniter, key, value) do
    args = igniter.args || %Args{}
    options = Keyword.put(args.options || [], key, value)
    %{igniter | args: %{args | options: options}}
  end
end
