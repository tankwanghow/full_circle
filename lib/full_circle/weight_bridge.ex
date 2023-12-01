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

  def goods_report(glist, fdate, tdate, com_id) do
    from(wei in Weighing,
      where: wei.company_id == ^com_id,
      where: wei.note_date >= ^fdate,
      where: wei.note_date <= ^tdate,
      where: wei.good_name in ^glist,
      select: %{
        good_name: wei.good_name,
        total: sum(wei.gross - wei.tare),
        month: fragment("extract(month from ?)::integer", wei.note_date),
        year: fragment("extract(year from ?)::integer", wei.note_date),
        unit: wei.unit
      },
      group_by: [
        wei.good_name,
        fragment("extract(month from ?)", wei.note_date),
        fragment("extract(year from ?)", wei.note_date),
        wei.unit
      ],
      order_by: [4, 3, 1]
    )
    |> Repo.all()
  end
end
