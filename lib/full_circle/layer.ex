defmodule FullCircle.Layer do
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  alias FullCircle.{Repo, Sys}
  alias FullCircle.Layer.{House, Flock, Movement, Harvest, HarvestDetail}

  def get_house_info_at(dt, h_no, com_id) do
    (house_info_query(dt, com_id) <> " and h.house_no = '#{h_no}'") |> exec_query() |> Enum.at(0)
  end

  def house_index(terms, com_id, page: page, per_page: per_page) do
    (house_info_query(Timex.today(), com_id) <>
       " order by COALESCE(WORD_SIMILARITY('#{terms}', h.house_no), 0) +" <>
       " COALESCE(WORD_SIMILARITY('#{terms}', info.flock_no), 0) desc" <>
       " limit #{per_page} offset #{(page - 1) * per_page}")
    |> exec_query()
  end

  defp house_info_query(dt, com_id) do
    "select h.id, h.house_no, h.capacity, info.flock_id, info.flock_no,
            coalesce(info.qty, 0) as qty, info.info_date
       from houses h
       left join (
         select h1.id as house_id, h1.house_no, h1.capacity, f2.id as flock_id, f2.flock_no,
                coalesce(max(h4.har_date), max(m0.move_date)) as info_date,
                sum(m0.quantity - coalesce(h3.dea_qty_1, 0) - coalesce(h3.dea_qty_2, 0)) as qty
           from houses as h1 left outer join movements as m0
             on h1.id = m0.house_id left outer join flocks as f2
             on f2.id = m0.flock_id left outer join harvest_details as h3
             on h1.id = h3.house_id and f2.id = h3.flock_id left outer join harvests as h4
             on h4.id = h3.harvest_id
          where m0.company_id = '#{com_id}'
            and coalesce(h4.har_date, m0.move_date) <= '#{dt}'
          group by h1.id, f2.id
         having sum(m0.quantity - coalesce(h3.dea_qty_1, 0) - coalesce(h3.dea_qty_2, 0)) > 0) info
         on info.house_id = h.id
       where true"
  end

  def get_flock!(id, com) do
    from(flk in Flock,
      preload: [movements: ^flock_movements()],
      where: flk.id == ^id,
      where: flk.company_id == ^com.id
    )
    |> Repo.one!()
  end

  defp flock_movements() do
    from(m in Movement,
      join: h in House,
      on: h.id == m.house_id,
      select: m,
      select_merge: %{house_no: h.house_no},
      order_by: [m.move_date, m.quantity]
    )
  end

  def get_house_by_no(no, com, _user) do
    no = no |> String.trim()

    from(hou in House,
      where: hou.company_id == ^com.id,
      where: hou.house_no == ^no,
      select: %{
        id: hou.id,
        value: hou.house_no
      },
      order_by: hou.house_no
    )
    |> Repo.one()
  end

  def houses_no(terms, com, _user) do
    from(hou in House,
      where: hou.company_id == ^com.id,
      where: ilike(hou.house_no, ^"%#{terms}%"),
      select: %{
        id: hou.id,
        value: hou.house_no
      },
      order_by: hou.house_no
    )
    |> Repo.all()
  end
end
