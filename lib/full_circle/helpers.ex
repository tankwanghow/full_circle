defmodule FullCircle.Helpers do
  import Ecto.Query, warn: false
  import Ecto.Changeset
  import FullCircleWeb.Gettext

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
end
