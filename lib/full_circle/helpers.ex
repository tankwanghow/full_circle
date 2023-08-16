defmodule FullCircle.Helpers do
  import Ecto.Query, warn: false
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  def list_hashtag(tag \\ "", class, key, com) do
    regexp = "#(\\w+#{tag}$|\\w+)"
    tag = "#%#{tag}%"

    FullCircle.Repo.all(
      from c in class,
        where: c.company_id == ^com.id,
        where: ilike(field(c, ^key), ^tag),
        select: fragment("distinct regexp_matches(?, ?, 'g')", field(c, ^key), ^regexp),
        order_by: 1
    )
    |> List.flatten()
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
        m = (c - Enum.find_index(fields, fn x -> x == col end)) |> :math.pow(3)

        dynamic(
          [cont],
          fragment("COALESCE(WORD_SIMILARITY(?,?),0)*?", ^term, field(cont, ^col), ^m)
        )
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
    if is_nil(fetch_field!(changeset, field_id)) and !is_nil(fetch_field!(changeset, field_name)) do
      changeset |> add_error(field_name, gettext("not in list"))
    else
      changeset
    end
  end

  def sum_struct_field_to(inval, detail_name, field_name, result_field) do
    dtls = Map.fetch!(inval, detail_name)

    sum =
      cond do
        is_struct(dtls, Ecto.Association.NotLoaded) ->
          Decimal.new("0")

        true ->
          Enum.reduce(dtls, Decimal.new("0"), fn x, acc ->
            Decimal.add(acc, Map.fetch!(x, field_name))
          end)
      end

    inval |> Map.replace!(result_field, sum)
  end

  def sum_field_to(changeset, detail_name, field_name, result_field) do
    dtls = get_change_or_data(changeset, detail_name)

    sum =
      cond do
        is_struct(dtls, Ecto.Association.NotLoaded) ->
          Decimal.new("0")

        true ->
          Enum.reduce(dtls, Decimal.new("0"), fn x, acc ->
            func =
              if is_struct(x, Ecto.Changeset) do
                &fetch_field!/2
              else
                &Map.fetch!/2
              end

            Decimal.add(
              acc,
              if(!func.(x, :delete),
                do: func.(x, field_name),
                else: Decimal.new("0")
              )
            )
          end)
      end

    changeset |> force_change(result_field, sum)
  end

  def get_change_or_data(changeset, detail_name) do
    if is_nil(get_change(changeset, detail_name)) do
      Map.fetch!(changeset.data, detail_name)
    else
      get_change(changeset, detail_name)
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

      {:ok, gen_doc_id(gap.current, doc_code)}
    end)
  end

  def gen_doc_id(number, code) do
    num = number |> Integer.to_string() |> String.pad_leading(6, "0")
    Enum.join([code, num], "-")
  end
end
