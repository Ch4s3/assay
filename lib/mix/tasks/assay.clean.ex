defmodule Mix.Tasks.Assay.Clean do
  @moduledoc false
  use Mix.Task

  alias Assay.Config

  @shortdoc "Remove Assay's incremental cache directory"

  @impl true
  def run([]) do
    config = config_module().from_mix_project()
    cache_dir = config.cache_dir
    existed? = File.exists?(cache_dir)

    case File.rm_rf(cache_dir) do
      {:ok, _} ->
        Mix.shell().info(clean_message(existed?, cache_dir, config.project_root))

      {:error, reason, file} ->
        Mix.raise("Unable to clean #{file}: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("mix assay.clean does not accept arguments")
  end

  defp clean_message(true, cache_dir, root) do
    "Removed #{relative_display(cache_dir, root)}"
  end

  defp clean_message(false, cache_dir, root) do
    "No cache directory found at #{relative_display(cache_dir, root)}"
  end

  defp config_module do
    Application.get_env(:assay, :config_module, Config)
  end

  defp relative_display(path, root) do
    relative =
      try do
        Path.relative_to(path, root)
      rescue
        _ -> path
      end

    if relative == "." do
      path
    else
      relative
    end
  end
end
