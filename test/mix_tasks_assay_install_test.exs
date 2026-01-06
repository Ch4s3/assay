defmodule Mix.Tasks.Assay.InstallTest do
  use ExUnit.Case, async: false

  alias Igniter.Mix.Task.Args
  alias Igniter.Test, as: IgniterTest
  alias Mix.Tasks.Assay.Install

  @detected %{project_apps: [:demo], all_apps: [:demo, :logger]}

  defmodule PromptShellYes do
    def info(_), do: :ok
    def error(_), do: :ok
    def prompt(_), do: "y"
  end

  defmodule PromptShellNo do
    def info(_), do: :ok
    def error(_), do: :ok
    def prompt(_), do: "n"
  end

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
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]

    mix_contents = Map.fetch!(files, "mix.exs")
    assert mix_contents =~ "assay: [dialyzer: [apps: [:demo], warning_apps: [:demo]]]"
    assert mix_contents =~ "{:assay, \"~> 0.1\", runtime: false, only: [:dev, :test]}"

    assert Map.fetch!(files, ".gitignore") == "_build/assay\n"

    assert Map.fetch!(files, "dialyzer_ignore.exs") =~
             "# %{file: \"lib/my_app.ex\", message: \"unknown function\"}"

    assert Map.fetch!(files, ".github/workflows/assay.yml") =~
             "mix assay --format github --format sarif"
  end

  test "installer can run at the root of umbrella projects" do
    assert Install.supports_umbrella?()
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
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    mix_contents = Map.fetch!(files, "mix.exs")
    assert mix_contents =~ "assay: [dialyzer: [apps: [:demo, :logger], warning_apps: [:demo]]]"
  end

  test "installer avoids duplicating gitignore entries" do
    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "_build/assay\n",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> put_option(:all_apps, false)
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    assert Map.fetch!(files, ".gitignore") == "_build/assay\n"
  end

  test "installer can scaffold gitlab CI when requested" do
    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> put_option(:ci, "gitlab")
      |> put_option(:all_apps, false)
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    assert Map.fetch!(files, ".gitlab-ci.yml") =~ "mix assay --format github --format sarif"
  end

  test "prompts to include extra apps when no options are provided" do
    previous_shell = Mix.shell()
    Mix.shell(PromptShellYes)
    on_exit(fn -> Mix.shell(previous_shell) end)

    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    mix_contents = Map.fetch!(files, "mix.exs")
    assert mix_contents =~ "assay: [dialyzer: [apps: [:demo, :logger], warning_apps: [:demo]]]"
  end

  test "skips extra apps when prompt is declined" do
    previous_shell = Mix.shell()
    Mix.shell(PromptShellNo)
    on_exit(fn -> Mix.shell(previous_shell) end)

    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    mix_contents = Map.fetch!(files, "mix.exs")
    assert mix_contents =~ "assay: [dialyzer: [apps: [:demo], warning_apps: [:demo]]]"
  end

  test "installer can skip CI scaffolding when requested" do
    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> put_option(:ci, "none")
      |> put_option(:all_apps, false)
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    refute Map.has_key?(files, ".github/workflows/assay.yml")
    refute Map.has_key?(files, ".gitlab-ci.yml")
  end

  test "installer supports atom-based ci options" do
    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> put_option(:ci, :gitlab)
      |> put_option(:all_apps, false)
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()

    files = igniter.assigns[:test_files]
    assert Map.fetch!(files, ".gitlab-ci.yml") =~ "mix assay --format github --format sarif"
  end

  test "installer rejects unsupported ci options" do
    igniter =
      IgniterTest.test_project(
        files: %{
          ".gitignore" => "",
          "mix.exs" => mixfile()
        }
      )
      |> Igniter.assign(:assay_detected_apps, @detected)
      |> put_option(:ci, "circle")
      |> put_option(:all_apps, false)

    assert_raise ArgumentError, fn ->
      igniter
      |> Install.igniter()
      |> IgniterTest.apply_igniter!()
    end
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
