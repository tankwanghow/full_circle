defmodule FullCircle.Repo.Migrations.SeedStatutoryFileFormats do
  use Ecto.Migration

  import Ecto.Query

  @bundle_path "priv/statutory_templates/malaysia.json"

  def up do
    bundle =
      Application.app_dir(:full_circle, @bundle_path)
      |> File.read!()
      |> Jason.decode!()

    time = DateTime.truncate(DateTime.utc_now(), :second)

    company_ids =
      repo().all(from(c in "companies", select: c.id))

    for company_id <- company_ids do
      seed_file_format_rows(bundle["file_formats"] || [], company_id, time)
    end
  end

  def down do
    execute("DELETE FROM statutory_file_formats")
  end

  defp seed_file_format_rows(entries, company_id, time) do
    rows =
      Enum.map(entries, fn entry ->
        %{
          id: Ecto.UUID.bingenerate(),
          company_id: company_id,
          code: entry["code"],
          name: entry["name"],
          effective_from: parse_date!(entry["effective_from"]),
          renderer: entry["renderer"] || "text",
          spec: entry["spec"] || %{},
          inserted_at: time,
          updated_at: time
        }
      end)

    if rows != [] do
      repo().insert_all("statutory_file_formats", rows,
        on_conflict: :nothing,
        conflict_target: [:company_id, :code, :effective_from]
      )
    end
  end

  defp parse_date!(iso) when is_binary(iso) do
    {:ok, date} = Date.from_iso8601(iso)
    date
  end
end