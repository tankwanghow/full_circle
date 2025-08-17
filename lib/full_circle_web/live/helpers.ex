defmodule FullCircleWeb.Helpers do
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  def assign_got_error(socket, assign_field, cs, list_name) do
    assign(
      socket,
      assign_field,
      if cs.changes[list_name] do
        if(cs.changes[list_name] |> Enum.find(fn x -> !x.valid? end),
          do: true,
          else: false
        )
      else
        false
      end
    )
  end

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

  def assign_autocomplete_id(socket, params, terms_name, assign_id, get_id_func) do
    terms = params[terms_name] |> String.trim()
    rec = get_id_func.(terms, socket.assigns.current_company, socket.assigns.current_user)
    params = Map.merge(params, %{assign_id => Util.attempt(rec, :id)})
    {params, socket, rec}
  end

  def assign_autocomplete_ids(socket, params, terms_name, assign_ids, get_id_func) do
    terms = params[terms_name] |> String.trim()
    rec = get_id_func.(terms, socket.assigns.current_company, socket.assigns.current_user)

    rtn =
      Enum.map(assign_ids, fn {k, v} -> %{k => Util.attempt(rec, v)} end)
      |> Enum.reduce(fn acc, x -> Map.merge(acc, x) end)

    {Map.merge(params, rtn), socket, rec}
  end

  def merge_detail(attrs, details_key, id, new_detail) do
    details = attrs[details_key] |> Map.merge(%{id => new_detail})
    attrs |> Map.merge(%{details_key => details})
  end

  def delete_line(cs, index, lines_name) do
    existing = Ecto.Changeset.get_assoc(cs, lines_name)
    {to_delete, rest} = List.pop_at(existing, String.to_integer(index))

    lines =
      if Ecto.Changeset.change(to_delete).data.id do
        List.replace_at(
          existing,
          String.to_integer(index),
          Ecto.Changeset.change(to_delete, delete: true)
        )
      else
        rest
      end

    cs |> Ecto.Changeset.put_assoc(lines_name, lines)
  end

  def add_line(cs, lines_name, params \\ %{}) do
    existing = Ecto.Changeset.get_assoc(cs, lines_name)
    Ecto.Changeset.put_assoc(cs, lines_name, existing ++ [params])
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

  def work_week(stamp) do
    {y, w} = stamp |> Timex.iso_week()
    y = "#{y}"
    w = String.reverse("0#{w}") |> String.slice(0..1) |> String.reverse()
    "#{y}/#{w}"
  end

  def insert_new_html_newline(str) do
    Phoenix.HTML.html_escape(str || "")
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("\n", "<br/>")
    |> Phoenix.HTML.raw()
  end

  def format_date(date) do
    if is_nil(date) do
      nil
    else
      Timex.format!(Timex.to_date(date), "%d-%m-%Y", :strftime)
    end
  end

  def format_datetime(datetime, com) do
    if is_nil(datetime) do
      nil
    else
      Timex.format!(Timex.to_datetime(datetime, com.timezone), "%d-%m-%Y %H:%M:%S", :strftime)
    end
  end

  def can_print?(socket, selected_name, max_selected) do
    if socket.assigns[selected_name] |> Enum.count() > max_selected do
      socket
      |> assign(can_print: false)
      |> Phoenix.LiveView.put_flash(
        :error,
        gettext("Please don't select more than ") <>
          (max_selected |> Integer.to_string()) <>
          gettext(" items.")
      )
    else
      socket |> assign(can_print: true)
    end
  end

  def int_or_float_format(n) do
    if(Decimal.eq?(n, Decimal.new("0")),
      do: "",
      else:
        if(Decimal.integer?(n),
          do: Decimal.to_integer(n) |> Number.Delimit.number_to_delimited(precision: 0),
          else: Number.Delimit.number_to_delimited(precision: 4)
        )
    )
  end

  def put_into_matchers(params, field, doc_date) do
    if params["transaction_matchers"] do
      mt =
        params["transaction_matchers"]
        |> Enum.reduce(%{}, fn {k, v}, acc ->
          Map.put(acc, k, Map.merge(v, %{field => doc_date}))
        end)

      Map.merge(params, %{"transaction_matchers" => mt})
    else
      params
    end
  end

  def make_timeattend_list(time_list, com) do
    in1 = make_timeattend(time_list, "1_IN_1", com)
    out1 = make_timeattend(time_list, "1_OUT_1", com)
    in2 = make_timeattend(time_list, "2_IN_2", com)
    out2 = make_timeattend(time_list, "2_OUT_2", com)
    in3 = make_timeattend(time_list, "3_IN_3", com)
    out3 = make_timeattend(time_list, "3_OUT_3", com)

    [in1, out1, in2, out2, in3, out3]
  end

  defp make_timeattend(time_list, flag, com) do
    ti = Enum.find(time_list, fn [_, _, _, inout] -> inout == flag end)

    if !is_nil(ti) do
      [time, id, status, inout] = ti

      if !is_nil(time) do
        {Timex.format!(
           Timex.to_datetime(time, com.timezone),
           "%H:%M",
           :strftime
         ), id, status, inout, Timex.to_datetime(time, com.timezone)}
      else
        {nil, "_new_#{FullCircle.Helpers.gen_temp_id(31)}", "normal", flag, nil}
      end
    else
      {nil, "_new_#{FullCircle.Helpers.gen_temp_id(31)}", "normal", flag, nil}
    end
  end
end
