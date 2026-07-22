# Import weekly sales (1–7) and purchase (P1–P7) books into egg_stock_dow_template_lines
# for Kim Poh Sitt Tat Feedmill Sdn Bhd (Egg Stock LiveView weekly books).
#
# Reads priv/repo/seeds/egg_dow_books.json (regenerate from ODS with parse_egg_ods_to_json.py).
#
# -----------------------------------------------------------------------------
# Local (dev DB):
#   mix run priv/repo/seeds/import_ods_egg_dow.exs
#
# Production DB from this machine (SSH tunnel — Postgres is loopback-only on server):
#   ssh -N -L 15432:127.0.0.1:5432 root@SERVER
#   DATABASE_URL='postgres://deployer:PASS@127.0.0.1:15432/fullcircle' \
#     mix run priv/repo/seeds/import_ods_egg_dow.exs
#
# Or: LINODE_PWD=… ./scripts/import_egg_dow_to_prod.sh
#
# Optional env:
#   EGG_DOW_COMPANY   — company name substring (default: "Kim Poh Sitt Tat")
#   EGG_DOW_JSON      — path to books JSON (default: priv/repo/seeds/egg_dow_books.json)
#   EGG_DOW_DRY_RUN=1 — match & print only, no DB writes
#   DATABASE_URL      — when set, overrides Repo URL (even under MIX_ENV=dev)
# -----------------------------------------------------------------------------

import Ecto.Query

alias FullCircle.Repo
alias FullCircle.EggStock
alias FullCircle.EggStock.DowTemplateLine
alias FullCircle.Accounting.Contact
alias FullCircle.Sys.{Company, CompanyUser}
alias FullCircle.UserAccounts.User

# mix run defaults to :dev (ignores runtime DATABASE_URL). Honour DATABASE_URL when set.
if database_url = System.get_env("DATABASE_URL") do
  for repo <- [FullCircle.Repo, FullCircle.QueryRepo] do
    current = Application.get_env(:full_circle, repo, [])

    Application.put_env(
      :full_circle,
      repo,
      Keyword.merge(current,
        url: database_url,
        username: nil,
        password: nil,
        hostname: nil,
        database: nil,
        pool_size: 5
      )
    )
  end

  # Restart the app so Repo/QueryRepo reconnect with the new URL
  Application.stop(:full_circle)
  {:ok, _} = Application.ensure_all_started(:full_circle)
  IO.puts("Repo URL overridden from DATABASE_URL (app restarted)")
end

dry_run? = System.get_env("EGG_DOW_DRY_RUN") in ["1", "true", "yes"]
company_query = System.get_env("EGG_DOW_COMPANY") || "Kim Poh Sitt Tat"

books_path =
  System.get_env("EGG_DOW_JSON") ||
    Path.expand("egg_dow_books.json", Path.dirname(__ENV__.file))

unless File.exists?(books_path) do
  Mix.raise("""
  Missing books JSON: #{books_path}

  Generate it from the ODS first:
    python3 priv/repo/seeds/parse_egg_ods_to_json.py "/path/to/Egg Est Left.ods"
  """)
end

books = books_path |> File.read!() |> Jason.decode!()

company =
  from(c in Company,
    where: ilike(c.name, ^"%#{company_query}%"),
    order_by: c.name,
    limit: 1
  )
  |> Repo.one() ||
    Mix.raise("No company matching %#{company_query}%")

company_id = company.id

user =
  from(u in User,
    join: cu in CompanyUser,
    on: cu.user_id == u.id,
    where: cu.company_id == ^company_id,
    order_by: [asc: u.email],
    limit: 1
  )
  |> Repo.one() ||
    Mix.raise("No user linked to company #{company.name}")

IO.puts("Company: #{company.name} (#{company_id})")
IO.puts("User:    #{user.email}")
IO.puts("Books:   #{books_path}")
IO.puts("Source:  #{get_in(books, ["meta", "source"]) || "?"}")
IO.puts(if(dry_run?, do: "MODE:    DRY RUN (no writes)\n", else: "MODE:    IMPORT\n"))

grades =
  from(g in FullCircle.EggStock.EggGrade,
    where: g.company_id == ^company_id,
    order_by: g.position
  )
  |> Repo.all()

if grades == [] do
  Mix.raise("""
  No egg grades for #{company.name}.
  Open Egg Stock → Settings and create grades (AA, A, B, C, D, E, F, Cr, W, …) first.
  """)
end

grade_by_nick =
  Map.new(grades, fn g ->
    nick =
      (g.nickname || g.name)
      |> to_string()
      |> String.trim()
      |> String.upcase()

    {nick, g.name}
  end)

# Also accept full grade name / stripped variants
grade_by_nick =
  Enum.reduce(grades, grade_by_nick, fn g, acc ->
    name = g.name |> to_string() |> String.trim()
    up = String.upcase(name)
    acc |> Map.put(up, g.name) |> Map.put(name, g.name)
  end)

IO.puts("Grades (nick → name):")

Enum.each(grades, fn g ->
  IO.puts("  #{inspect(g.nickname)} → #{inspect(g.name)}")
end)

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

# Explicit ODS short names → preferred FullCircle contact (normalized keys)
aliases = %{
  "ylf" => "yeong lai foong",
  "yeong lai foong" => "yeong lai foong",
  "qing" => "soon kim yuan",
  "ah qing" => "soon kim yuan",
  "zl" => "zl nutrieggs",
  "syl marketing" => "sin yew lee marketing",
  "sin yew lee marketing" => "sin yew lee marketing",
  "wong brother" => "wong brothers trading co",
  "wwb" => "wwb top trading",
  "xin seng tat" => "xin seng tat",
  "easy by shop" => "easy by shop",
  "swee heng" => "chop swee heng",
  "foong kin" => "foong kin trading",
  "hock hen" => "hock hen khoon",
  "heng huat" => "heng huat",
  "jnj" => "jnj lgk",
  "chang jiang" => "chop chang jiang",
  "new weng fatt" => "new weng fatt agricultural",
  "golden sunrise" => "golden sunrise trading",
  "sem ah yem" => "pasaraya sem ah yem",
  "sheng wai" => "sheng wai food",
  "shun loong" => "shun loong trading",
  "meng fatt" => "meng fatt trading",
  "hong you" => "hong you trading",
  "teet chong" => "teet chong",
  "sum kee" => "sum kee trading",
  "sin kean hin" => "sin kean hin mart",
  "hua hing" => "hua hing enterprise",
  "mvd" => "mvd express",
  "huat soon" => "huat soon trading",
  "hocksoon" => "hock soon poultry",
  "hock soon" => "hock soon poultry",
  "cm best" => "cm best holdings",
  "joo how" => "joo how trading",
  "cindy" => "cindy",
  "fukuro" => "fukuro",
  "extra" => "extra",
  "extra+" => "extra"
}

find_contact = fn ods_name ->
  raw_key = normalize.(ods_name)
  key = normalize.(Map.get(aliases, raw_key, ods_name))

  scored =
    contacts
    |> Enum.map(fn {id, name} ->
      n = normalize.(name)

      score =
        cond do
          n == key ->
            100

          String.starts_with?(n, key) and String.length(key) >= 4 ->
            90 + String.length(key)

          String.contains?(n, key) and String.length(key) >= 4 ->
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
  Enum.reduce(qty_map || %{}, %{}, fn {k, v}, acc ->
    nick = k |> to_string() |> String.trim() |> String.upcase()
    # ODS uses Cr; grades may use CR / Crack nickname
    nick = if nick in ["CR", "CRACK", "PECAH"], do: "CR", else: nick
    nick = if nick in ["W", "WHITE", "PUTIH"], do: "W", else: nick
    nick = if nick in ["DR", "DIRTY", "TAHI"], do: "DR", else: nick

    # Prefer exact nickname key; also try CR when nick is CR
    gname =
      Map.get(grade_by_nick, nick) ||
        Map.get(grade_by_nick, String.replace_prefix(nick, "EGG GRADE ", ""))

    cond do
      is_nil(gname) ->
        IO.puts("  WARN unknown grade #{inspect(k)} (nick=#{nick})")
        acc

      true ->
        Map.put(acc, gname, trunc(v))
    end
  end)
end

# Build params list for one DOW book
build_params = fn lines ->
  Enum.map(lines, fn line ->
    if line["separator"] in [true, "true"] do
      %{
        "id" => "",
        "contact_id" => nil,
        "contact_name" => "",
        "quantities" => %{},
        "is_separator" => true,
        "group_name" => line["name"] || "",
        "delete" => "false"
      }
    else
      ods_name = line["name"]
      quantities = map_qty.(line["quantities"] || %{})

      {contact_id, contact_name, note} =
        case find_contact.(ods_name) do
          {:ok, id, name, s} -> {id, name, "ok:#{s}"}
          {:weak, id, name, s} -> {id, name, "weak:#{s}"}
          # Ad-hoc: store ODS label with no contact_id (egg stock accepts free-text names)
          :none -> {nil, ods_name, "ADHOC"}
        end

      sum = quantities |> Map.values() |> Enum.sum()

      IO.puts(
        "  #{ods_name} → #{contact_name} (#{note}) sum=#{sum} q=#{inspect(line["quantities"])}"
      )

      %{
        "id" => "",
        "contact_id" => contact_id,
        "contact_name" => contact_name,
        "quantities" => quantities,
        "is_separator" => false,
        "group_name" => "",
        "delete" => "false"
      }
    end
  end)
end

if dry_run? do
  for kind <- ["sales", "purchase"] do
    for {dow_str, lines} <- books[kind] || %{} do
      IO.puts("\n=== DRY #{kind} DOW #{dow_str} (#{length(lines)} raw lines) ===")
      _ = build_params.(lines)
    end
  end

  IO.puts("\nDry run complete — no changes written.")
else
  {deleted, _} =
    from(l in DowTemplateLine, where: l.company_id == ^company_id)
    |> Repo.delete_all()

  IO.puts("Cleared #{deleted} existing DOW lines\n")

  for kind <- ["sales", "purchase"] do
    for {dow_str, lines} <- books[kind] || %{} do
      dow = String.to_integer(dow_str)
      IO.puts("=== #{kind} DOW #{dow} ===")
      params = build_params.(lines)

      case EggStock.save_dow_lines(company_id, kind, dow, params, company, user) do
        {:ok, saved} ->
          IO.puts("  => saved #{length(saved)} lines\n")

        {:error, cs} ->
          IO.inspect(cs, label: "ERROR #{kind} #{dow}")

        :not_authorise ->
          IO.puts("NOT AUTHORISED for #{kind} #{dow} (user needs update_egg_stock_day)")
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
  IO.puts("\nDone. Open Egg Stock → Weekly Sales / Weekly Purchases to verify.")
end
