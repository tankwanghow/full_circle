defmodule Mix.Tasks.Statutory.Validate do
  @shortdoc "Validate a statutory bundle JSON file offline"
  @moduledoc false

  use Mix.Task

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, bundle} ->
            case FullCircle.StatutoryConfig.validate_bundle(bundle) do
              :ok ->
                Mix.shell().info("bundle OK")
                :ok

              {:error, errors} ->
                for err <- errors, do: Mix.shell().error(err)
                Mix.raise("bundle validation failed")
            end

          {:error, reason} ->
            Mix.raise("invalid JSON: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("could not read #{path}: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("usage: mix statutory.validate <path.json>")
  end
end