defmodule FullCircleWeb.Helpers do
  use Phoenix.Component

  def list_n_value(socket, terms, list_fn) do
    list = list_fn.(terms, socket.assigns.current_company, socket.assigns.current_user)

    value =
      Enum.find(list, fn x ->
        x.value == terms
      end)

    {list, value}
  end

  def assign_list_n_id(socket, params, terms_name, assign_names, assign_id, list_func) do
    terms = params[terms_name]

    {l, v} = list_n_value(socket, terms, list_func)

    params = Map.merge(params, %{assign_id => Util.attempt(v, :id) || -1})
    {params, socket |> assign(assign_names, l), v}
  end

  def merge_detail(attrs, details_key, id, new_detail) do
    details = attrs[details_key] |> Map.merge(%{id => new_detail})
    attrs |> Map.merge(%{details_key => details})
  end

  defp get_change_or_field(changeset, field) do
    with nil <- Ecto.Changeset.get_change(changeset, field) do
      Ecto.Changeset.get_field(changeset, field, [])
    end
  end

  def delete_lines(socket, index, lines_name) do
    update(socket, :form, fn %{source: changeset} ->
      existing = get_change_or_field(changeset, lines_name)
      {to_delete, rest} = List.pop_at(existing, index)

      lines =
        if Ecto.Changeset.change(to_delete).data.id do
          List.replace_at(existing, index, Ecto.Changeset.change(to_delete, delete: true))
        else
          rest
        end

      changeset
      |> Ecto.Changeset.put_assoc(lines_name, lines)
      |> to_form()
    end)
  end

  def add_lines(socket, lines_name, line_class_struct) do
    update(socket, :form, fn %{source: changeset} ->
      existing = get_change_or_field(changeset, lines_name)

      changeset = Ecto.Changeset.put_assoc(changeset, lines_name, existing ++ [line_class_struct])

      to_form(changeset)
    end)
  end

  def format_unit_price(number) do
    if Decimal.eq?(number, 0) do
      "FOC"
    else
      if Decimal.lt?(number, 100) do
        Number.Delimit.number_to_delimited(number, precision: 4)
      else
        Number.Delimit.number_to_delimited(number, precision: 2)
      end
    end
  end

  def insert_new_html_newline(str) do
    Phoenix.HTML.html_escape(str || "")
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("\n", "<br/>")
    |> Phoenix.HTML.raw()
  end

  def make_log_delta_to_html(delta) do
    delta
    |> String.replace("&^", "<p>")
    |> String.replace("^&", "</p>")
    |> String.replace("[", "<div class='pl-4'>")
    |> String.replace("]", "</div>")
    |> String.replace("<!", "<span class='text-red-500 line-through'>")
    |> String.replace("!>", "</span>")
    |> String.replace("<$", "<span class='text-green-600'>")
    |> String.replace("$>", "</span>")
  end

  def put_marker_in_diff_log_delta(a1, a2) do
    String.myers_difference(a1, a2)
    |> Enum.map_join(fn {k, v} ->
      case k do
        :del -> "<!#{v}!>"
        :ins -> "<$#{v}$>"
        _ -> v
      end
    end)
  end

  def format_date(date) do
    Timex.format!(Timex.local(date), "%d-%m-%Y", :strftime)
  end
end
