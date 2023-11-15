defmodule FullCircle.WeightBridge do
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  alias FullCircle.WeightBridge.Weighing
  alias FullCircle.{Repo, Sys}

  def get_print_weighings!(ids, company, user) do
    Repo.all(
      from wei in Weighing,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == wei.company_id,
        where: wei.id in ^ids,
        select: wei
    )
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("weighings", x.id, x.company_id)})
    end)
  end
end
