defmodule FullCircle.Tugas do
  @moduledoc """
  Duties: what has to get done, who moved it along, and what proves it.

  Three things hang off a duty:

    * **events** — an append-only trail (`progress`, `done`, `skip`, `linked`,
      `unlinked`, `end_series`). Events are the record; the duty row is just
      the current state.
    * **evidence** — files attached to an event.
    * **documents** — links to real FullCircle documents (`duty_documents`).
      One duty can point at many documents.

  Closing a cycle and spawning the next happen in one `Ecto.Multi`, so a duty
  series can never be left with zero live cycles or two.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.Repo
  alias FullCircle.StdInterface
  alias FullCircle.Sys
  alias FullCircle.Tugas.Duty

  @doc """
  Document types a duty may be linked to.

  Deliberately a whitelist: `duty_documents.doc_id` carries no foreign key, so
  this list is the only thing keeping the column pointed at real tables.
  """
  def document_types, do: ~w(Payment)

  def query(Duty, company, user) do
    from(d in Duty,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == d.company_id,
      select: d
    )
  end

  # --- DUTIES ---------------------------------------------------------------

  def create_duty(attrs, com, user) do
    attrs =
      attrs
      |> FullCircle.Helpers.key_to_string()
      |> Map.put_new("series_id", Ecto.UUID.generate())
      |> Map.put("status", "active")

    StdInterface.create(Duty, "duty", attrs, com, user)
  end
end
