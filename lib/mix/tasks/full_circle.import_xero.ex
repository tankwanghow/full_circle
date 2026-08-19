defmodule Mix.Tasks.FullCircle.ImportXero do
  @shortdoc "Import a Xero snapshot into Full Circle"

  @moduledoc """
  Offline Xero → Full Circle import.

      mix full_circle.import_xero --dry-run --snapshot-dir PATH --user EMAIL
      mix full_circle.import_xero --apply --snapshot-dir PATH --user EMAIL [--reset]
      mix full_circle.import_xero --reconcile --snapshot-dir PATH --user EMAIL [--company NAME]

  Default `--snapshot-dir` is `priv/xero_import/golden_husbandry`.
  `--user` falls back to env `FC_IMPORT_USER`.
  `--reconcile` needs an existing company (`--company`, default Golden Husbandry Sdn. Bhd.).

  `--auth` and `--snapshot` are not implemented in this task (see Task 10).
  """

  use Mix.Task

  import Ecto.Query, warn: false

  alias FullCircle.XeroImport
  alias FullCircle.XeroImport.{Apply, Reconcile}
  alias FullCircle.Repo
  alias FullCircle.Sys.{Company, CompanyUser}

  @default_snapshot_dir "priv/xero_import/golden_husbandry"
  @default_company_name "Golden Husbandry Sdn. Bhd."

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          auth: :boolean,
          snapshot: :boolean,
          dry_run: :boolean,
          apply: :boolean,
          reset: :boolean,
          reconcile: :boolean,
          user: :string,
          company: :string,
          snapshot_dir: :string,
          log: :string
        ]
      )

    cond do
      opts[:auth] ->
        stub!("not implemented")

      opts[:snapshot] ->
        stub!("not implemented")

      opts[:dry_run] ->
        Mix.Task.run("app.start")
        dry_run!(opts)

      opts[:apply] ->
        Mix.Task.run("app.start")
        apply!(opts)

      opts[:reconcile] ->
        Mix.Task.run("app.start")
        reconcile!(opts)

      true ->
        stub!(
          "usage: mix full_circle.import_xero --dry-run|--apply|--reconcile [--reset] [--user EMAIL] [--company NAME] [--snapshot-dir PATH]"
        )
    end
  end

  defp dry_run!(opts) do
    dir = snapshot_dir(opts)

    with {:ok, snap} <- XeroImport.read_snapshot(dir),
         {:ok, result} <- XeroImport.dry_run(snap, %{overrides: load_overrides(dir)}) do
      text = format_dry_run(result)
      Mix.shell().info(text)
      maybe_log(dir, opts, text)

      if result.errors == [] do
        :ok
      else
        halt!(format_errors(result.errors))
      end
    else
      {:error, reason} -> halt!(inspect(reason))
    end
  end

  defp apply!(opts) do
    dir = snapshot_dir(opts)

    with {:ok, user} <- resolve_user(opts),
         {:ok, snap} <- XeroImport.read_snapshot(dir),
         {:ok, result} <-
           Apply.run(snap, user, reset: opts[:reset] == true, overrides: load_overrides(dir)) do
      text = "applied company=#{result.company.name} id=#{result.company.id}"
      Mix.shell().info(text)
      maybe_log(dir, opts, text)
      :ok
    else
      {:error, :company_not_empty} ->
        halt!(":company_not_empty")

      {:error, reason} ->
        halt!(inspect(reason))
    end
  end

  defp reconcile!(opts) do
    dir = snapshot_dir(opts)
    name = opts[:company] || @default_company_name

    with {:ok, user} <- resolve_user(opts),
         {:ok, snap} <- XeroImport.read_snapshot(dir),
         {:ok, company} <- find_company(name, user),
         result <- Reconcile.run(snap, company, user) do
      text = format_reconcile(result, company)
      Mix.shell().info(text)
      maybe_log(dir, opts, text)

      case result do
        {:ok, _} -> :ok
        {:error, _} -> halt!("reconcile failed")
      end
    else
      {:error, reason} -> halt!(inspect(reason))
    end
  end

  defp find_company(name, user) do
    company =
      Repo.one(
        from c in Company,
          join: cu in CompanyUser,
          on: cu.company_id == c.id,
          where: c.name == ^name and cu.user_id == ^user.id,
          limit: 1
      )

    if company, do: {:ok, company}, else: {:error, {:company_not_found, name}}
  end

  defp snapshot_dir(opts), do: opts[:snapshot_dir] || @default_snapshot_dir

  defp resolve_user(opts) do
    email = opts[:user] || System.get_env("FC_IMPORT_USER")

    cond do
      is_nil(email) or email == "" ->
        {:error, :missing_user}

      true ->
        case FullCircle.UserAccounts.get_user_by_email(email) do
          nil -> {:error, {:user_not_found, email}}
          user -> {:ok, user}
        end
    end
  end

  defp load_overrides(snapshot_dir) do
    [
      Path.join(snapshot_dir, "overrides.json"),
      Path.expand("priv/xero_import/overrides.json")
    ]
    |> Enum.find_value(%{}, fn path ->
      case File.read(path) do
        {:ok, bin} ->
          case Jason.decode(bin) do
            {:ok, map} when is_map(map) -> map
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp format_dry_run(%{counts: counts, errors: errors}) do
    count_lines =
      [
        :accounts,
        :contacts,
        :invoices,
        :bills,
        :receipts,
        :payments,
        :journals,
        :assets,
        :skipped
      ]
      |> Enum.map(fn k -> "  #{k}: #{Map.get(counts, k, 0)}" end)
      |> Enum.join("\n")

    err_lines = format_errors(errors)

    """
    dry-run
    counts:
    #{count_lines}
    errors:
    #{err_lines}
    """
  end

  defp format_reconcile({status, %{checks: checks}}, company) do
    tag = if status == :ok, do: "ok", else: "FAIL"

    check_lines =
      checks
      |> Enum.map(&format_check/1)
      |> Enum.join("\n")

    """
    reconcile #{tag} company=#{company.name} id=#{company.id}
    #{check_lines}
    """
  end

  defp format_check(%{name: name, ok?: true, diffs: _}) do
    "  #{name}: ok"
  end

  defp format_check(%{name: name, ok?: false, diffs: diffs}) do
    diff_lines =
      diffs
      |> Enum.map(&format_diff/1)
      |> Enum.join("\n")

    "  #{name}: FAIL\n#{diff_lines}"
  end

  defp format_diff(diff) do
    key = diff[:account_name] || diff[:contact_name] || diff[:name] || diff[:key]
    "    #{key} xero=#{diff[:xero]} full_circle=#{diff[:full_circle]} delta=#{diff[:delta]}"
  end

  defp format_errors([]), do: "  (none)"

  defp format_errors(errors) do
    errors
    |> Enum.map(&("  " <> inspect(&1)))
    |> Enum.join("\n")
  end

  defp maybe_log(dir, opts, text) do
    if log_enabled?(opts) do
      _ = File.write(Path.join(dir, "last_run.log"), text <> "\n", [:append])
    end
  end

  defp log_enabled?(opts) do
    case opts[:log] do
      "false" -> false
      "0" -> false
      "no" -> false
      "off" -> false
      _ -> true
    end
  end

  defp stub!(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end

  defp halt!(message) do
    Mix.shell().error(to_string(message))
    exit({:shutdown, 1})
  end
end
