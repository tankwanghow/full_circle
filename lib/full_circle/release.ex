defmodule FullCircle.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :full_circle

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Bank payment go-live: formats, profiles and supplier bank details from
  Payment descriptions. Dry run unless `dry_run: false`. See
  `FullCircle.BankPayment.Backfill`.

      bin/full_circle eval 'FullCircle.Release.bank_backfill("<company id>", "<admin email>", dry_run: true)'
  """
  def bank_backfill(company_id, admin_email, opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:tzdata)

    {:ok, result, _} =
      Ecto.Migrator.with_repo(FullCircle.Repo, fn _repo ->
        FullCircle.BankPayment.Backfill.run(company_id, admin_email, opts)
      end)

    case result do
      {:ok, report} -> IO.puts(FullCircle.BankPayment.Backfill.report(report))
      {:error, msg} -> IO.puts("ERROR: #{msg}")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
