# Import ODS weekly sales (1-7) and purchase (P1-P7) books into egg_stock_dow_template_lines.
# Usage: mix run priv/repo/seeds/import_ods_egg_dow.exs

import Ecto.Query

alias FullCircle.Repo
alias FullCircle.EggStock
alias FullCircle.EggStock.DowTemplateLine
alias FullCircle.Accounting.Contact
alias FullCircle.Sys.{Company, CompanyUser}
alias FullCircle.UserAccounts.User

company_id = "a2edcb0f-e9fb-4a8d-888b-61cd334210ba"
company = Repo.get!(Company, company_id)

user =
  from(u in User,
    join: cu in CompanyUser,
    on: cu.user_id == u.id,
    where: cu.company_id == ^company_id,
    limit: 1
  )
  |> Repo.one!()

IO.puts("Company: #{company.name}")
IO.puts("User: #{user.email}")

grades =
  from(g in FullCircle.EggStock.EggGrade,
    where: g.company_id == ^company_id,
    order_by: g.position
  )
  |> Repo.all()

grade_by_nick =
  Map.new(grades, fn g ->
    {String.upcase(String.trim(g.nickname || g.name)), g.name}
  end)

IO.puts("Grades: #{inspect(Map.keys(grade_by_nick))}")

contacts =
  from(c in Contact, where: c.company_id == ^company_id, select: {c.id, c.name})
  |> Repo.all()

normalize = fn s ->
  s
  |> to_string()
  |> String.downcase()
  |> String.replace(~r/[^a-z0-9]+/, " ")
  |> String.trim()
  |> String.replace(~r/\s+/, " ")
end

aliases = %{
  "ylf" => "yeong lai foong",
  "qing" => "qing",
  "zl" => "zl nutrieggs",
  "syl marketing" => "sin yew lee",
  "sin yew lee marketing" => "sin yew lee",
  "wong brother" => "wong brothers",
  "xin seng tat" => "xin seng tat",
  "easy by shop" => "easy by shop"
}

find_contact = fn ods_name ->
  key = normalize.(Map.get(aliases, normalize.(ods_name), ods_name))

  scored =
    contacts
    |> Enum.map(fn {id, name} ->
      n = normalize.(name)

      score =
        cond do
          n == key ->
            100

          String.contains?(n, key) ->
            80 + String.length(key)

          String.contains?(key, n) and String.length(n) >= 4 ->
            60 + String.length(n)

          true ->
            kt = key |> String.split() |> MapSet.new()
            nt = n |> String.split() |> MapSet.new()
            inter = MapSet.intersection(kt, nt) |> MapSet.size()

            cond do
              inter > 0 and inter == MapSet.size(kt) -> 50 + inter * 5
              inter >= 2 -> 30 + inter
              true -> 0
            end
        end

      {score, id, name}
    end)
    |> Enum.filter(fn {s, _, _} -> s > 0 end)
    |> Enum.sort_by(fn {s, _, name} -> {-s, String.length(name)} end)

  case scored do
    [{s, id, name} | _] when s >= 50 -> {:ok, id, name, s}
    [{s, id, name} | _] -> {:weak, id, name, s}
    [] -> :none
  end
end

map_qty = fn qty_map ->
  Enum.reduce(qty_map, %{}, fn {k, v}, acc ->
    nick = String.upcase(String.trim(to_string(k)))

    case Map.get(grade_by_nick, nick) do
      nil ->
        IO.puts("  WARN unknown grade #{inspect(k)}")
        acc

      gname ->
        Map.put(acc, gname, trunc(v))
    end
  end)
end

books_path = "/tmp/egg_dow_books.json"
books = books_path |> File.read!() |> Jason.decode!()

{deleted, _} =
  from(l in DowTemplateLine, where: l.company_id == ^company_id)
  |> Repo.delete_all()

IO.puts("Cleared #{deleted} existing DOW lines\n")

unmatched = :ets.new(:unmatched, [:set])

for kind <- ["sales", "purchase"] do
  for {dow_str, lines} <- books[kind] do
    dow = String.to_integer(dow_str)

    params =
      Enum.map(lines, fn line ->
        ods_name = line["name"]
        quantities = map_qty.(line["quantities"] || %{})

        {contact_id, contact_name, note} =
          case find_contact.(ods_name) do
            {:ok, id, name, s} -> {id, name, "ok:#{s}"}
            {:weak, id, name, s} -> {id, name, "weak:#{s}"}
            :none -> {nil, ods_name, "NONE"}
          end

        if note == "NONE", do: :ets.insert(unmatched, {ods_name, true})

        IO.puts(
          "[#{kind} #{dow}] #{ods_name} -> #{contact_name} (#{note}) sum=#{Enum.sum(Map.values(quantities))}"
        )

        %{
          "id" => "",
          "contact_id" => contact_id,
          "contact_name" => contact_name,
          "quantities" => quantities,
          "delete" => "false"
        }
      end)

    case EggStock.save_dow_lines(company_id, kind, dow, params, company, user) do
      {:ok, saved} ->
        IO.puts("  => saved #{length(saved)} lines\n")

      {:error, cs} ->
        IO.inspect(cs, label: "ERROR #{kind} #{dow}")

      :not_authorise ->
        IO.puts("NOT AUTHORISED for #{kind} #{dow}")
    end
  end
end

counts =
  from(l in DowTemplateLine,
    where: l.company_id == ^company_id,
    group_by: [l.kind, l.dow],
    select: {l.kind, l.dow, count(l.id)},
    order_by: [l.kind, l.dow]
  )
  |> Repo.all()

IO.puts("\nFinal line counts (kind, dow, count):")
Enum.each(counts, &IO.inspect/1)

unmatched_names = :ets.tab2list(unmatched) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

if unmatched_names != [] do
  IO.puts("\nUnmatched ODS contacts (stored with name only, no contact_id):")
  Enum.each(unmatched_names, &IO.puts("  - #{&1}"))
else
  IO.puts("\nAll ODS contacts matched to FullCircle contacts.")
end
