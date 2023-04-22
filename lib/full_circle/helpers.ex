defmodule FullCircle.Helpers do
  import Ecto.Query, warn: false
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  def list_hashtag(tag \\ "", class, key, com) do
    regexp = "#(#{tag}\\w+)"

    FullCircle.Repo.all(
      from c in class,
        where: c.company_id == ^com.company_id,
        select: fragment("distinct regexp_matches(?, ?, 'g')", field(c, ^key), ^regexp)
    )
    |> List.flatten()
    |> Enum.sort()
  end

  def gen_temp_id(val \\ 6),
    do:
      :crypto.strong_rand_bytes(val)
      |> Base.encode32(case: :lower, padding: false)
      |> binary_part(0, val)

  def similarity_order(fields, terms) do
    texts =
      String.split(terms, " ")
      |> Enum.filter(fn x -> !String.starts_with?(x, "#") end)

    c = Enum.count(fields)

    x =
      for col <- fields, term <- texts do
        m = c - Enum.find_index(fields, fn x -> x == col end)
        dynamic([cont], fragment("COALESCE(SIMILARITY(?,?),0)*?", field(cont, ^col), ^term, ^m))
      end
      |> Enum.reduce(fn a, b -> dynamic(^a + ^b) end)

    [desc: x]
  end

  def get_entity_from_multi_tuple(multi, name) do
    Map.get(
      multi,
      multi
      |> Map.keys()
      |> Enum.filter(fn x -> is_tuple(x) end)
      |> Enum.find(fn {x, _} -> x == name end)
    )
  end

  def key_to_string(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end

  def validate_id(changeset, field_name, field_id) do
    if Map.has_key?(changeset.changes, field_id) do
      if get_change(changeset, field_id) == -1 do
        changeset |> add_error(field_name, gettext("not in list"))
      else
        changeset
      end
    else
      changeset
    end
  end

  def get_gapless_doc_id(multi, name, doc, doc_code, com) do
    Ecto.Multi.run(multi, name, fn repo, _ ->
      gap =
        repo.one(
          from gap in FullCircle.Sys.GaplessDocId,
            where: gap.company_id == ^com.id,
            where: gap.doc_type == ^doc,
            select: gap
        )

      {:ok, gap} =
        repo.update(Ecto.Changeset.change(gap, current: gap.current + 1), returning: [:current])

      {:ok, gen_doc_id(gap.current, doc_code, com.id)}
    end)
  end

  def gen_doc_id(number, code, company_id) do
    num = number |> Integer.to_string() |> String.pad_leading(6, "0")
    com = company_id |> Integer.to_string()
    Enum.join([code, com, num], "-")
  end
end
