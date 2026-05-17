defmodule FullCircleWeb.ReportLive.Aging do
  use FullCircleWeb, :live_view

  alias FullCircle.Reporting.AgingBuckets

  @selected_max 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Aging List")
     |> assign(selected_ids: MapSet.new())
     |> assign(can_print: false)
     |> assign(sort_by: :contact_name)
     |> assign(sort_dir: :asc)
     |> assign(drill: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"] || %{}
    report = params["report"]
    t_date = params["t_date"] || Timex.today()

    cutoffs = AgingBuckets.parse_cutoffs(params)
    preset = AgingBuckets.preset_for(cutoffs)

    search = %{
      report: report,
      t_date: t_date,
      preset: preset,
      c1: Enum.at(cutoffs, 0),
      c2: Enum.at(cutoffs, 1),
      c3: Enum.at(cutoffs, 2),
      c4: Enum.at(cutoffs, 3)
    }

    {:noreply,
     socket
     |> assign(search: search)
     |> assign(cutoffs: cutoffs)
     |> assign(selected_ids: MapSet.new())
     |> assign(can_print: false)
     |> filter_transactions(report, t_date, cutoffs)}
  end

  @impl true
  def handle_event(
        "changed",
        %{"_target" => ["search", "preset"], "search" => %{"preset" => preset}},
        socket
      ) do
    search =
      case Map.fetch(AgingBuckets.presets(), preset) do
        {:ok, [c1, c2, c3, c4]} ->
          Map.merge(socket.assigns.search, %{preset: preset, c1: c1, c2: c2, c3: c3, c4: c4})

        :error ->
          Map.put(socket.assigns.search, :preset, preset)
      end

    {:noreply, assign(socket, search: search)}
  end

  def handle_event(
        "changed",
        %{"_target" => ["search", field], "search" => params},
        socket
      )
      when field in ["c1", "c2", "c3", "c4"] do
    cutoffs = AgingBuckets.parse_cutoffs(params)

    search =
      socket.assigns.search
      |> Map.merge(%{
        c1: Enum.at(cutoffs, 0),
        c2: Enum.at(cutoffs, 1),
        c3: Enum.at(cutoffs, 2),
        c4: Enum.at(cutoffs, 3),
        preset: AgingBuckets.preset_for(cutoffs)
      })

    {:noreply, assign(socket, search: search)}
  end

  def handle_event("changed", _, socket), do: {:noreply, socket}

  def handle_event("query", %{"search" => params}, socket) do
    cutoffs = AgingBuckets.parse_cutoffs(params)

    qry = %{
      "search[t_date]" => params["t_date"],
      "search[report]" => params["report"],
      "search[c1]" => Enum.at(cutoffs, 0),
      "search[c2]" => Enum.at(cutoffs, 1),
      "search[c3]" => Enum.at(cutoffs, 2),
      "search[c4]" => Enum.at(cutoffs, 3)
    }

    url = "/companies/#{socket.assigns.current_company.id}/aging?#{URI.encode_query(qry)}"

    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)
    %{sort_by: cur_field, sort_dir: cur_dir} = socket.assigns

    {sort_by, sort_dir} =
      if field == cur_field do
        {field, toggle_dir(cur_dir)}
      else
        {field, default_dir(field)}
      end

    {:noreply, socket |> assign(sort_by: sort_by, sort_dir: sort_dir)}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    {:noreply,
     socket
     |> assign(selected_ids: selected)
     |> FullCircleWeb.Helpers.can_print?(:selected_ids, @selected_max)}
  end

  def handle_event(
        "drill",
        %{"contact_id" => contact_id, "bucket" => bucket, "name" => name},
        socket
      ) do
    {lo, hi} = bucket_range(bucket, socket.assigns.cutoffs)
    label = bucket_label_for(bucket, socket.assigns.cutoffs)

    rows =
      FullCircle.Reporting.contact_bucket_transactions(
        socket.assigns.search.t_date,
        socket.assigns.current_company.id,
        contact_id,
        lo,
        hi
      )

    {:noreply,
     assign(socket, drill: %{contact_name: name, bucket_label: label, rows: rows})}
  end

  def handle_event("close_drill", _params, socket) do
    {:noreply, assign(socket, drill: nil)}
  end

  def handle_event("toggle_all", _params, socket) do
    rows = current_rows(socket.assigns)
    all_ids = Enum.map(rows, & &1.contact_id) |> MapSet.new()

    selected =
      if MapSet.subset?(all_ids, socket.assigns.selected_ids) and MapSet.size(all_ids) > 0 do
        MapSet.difference(socket.assigns.selected_ids, all_ids)
      else
        MapSet.union(socket.assigns.selected_ids, all_ids)
      end

    {:noreply,
     socket
     |> assign(selected_ids: selected)
     |> FullCircleWeb.Helpers.can_print?(:selected_ids, @selected_max)}
  end

  defp current_rows(%{result: %{ok?: true, result: rows}}) when is_list(rows), do: rows
  defp current_rows(_), do: []

  defp bucket_range("p1", [c1, _, _, _]), do: {nil, c1}
  defp bucket_range("p2", [c1, c2, _, _]), do: {c1, c2}
  defp bucket_range("p3", [_, c2, c3, _]), do: {c2, c3}
  defp bucket_range("p4", [_, _, c3, c4]), do: {c3, c4}
  defp bucket_range("p5", [_, _, _, c4]), do: {c4, nil}

  defp bucket_label_for(bucket, cutoffs) do
    idx = %{"p1" => 0, "p2" => 1, "p3" => 2, "p4" => 3, "p5" => 4}[bucket]
    Enum.at(AgingBuckets.bucket_labels(cutoffs), idx)
  end

  defp filter_transactions(socket, report, t_date, cutoffs) do
    current_company = socket.assigns.current_company

    assign_async(socket, :result, fn ->
      {:ok,
       %{
         result:
           cond do
             report == "Debtors Aging" ->
               FullCircle.Reporting.debtor_aging_report(t_date, cutoffs, current_company.id)

             report == "Creditors Aging" ->
               FullCircle.Reporting.creditor_aging_report(t_date, cutoffs, current_company.id)

             true ->
               []
           end
       }}
    end)
  end

  defp sort_rows(rows, field, dir) do
    Enum.sort_by(rows, &sort_key(&1, field), dir)
  end

  defp sort_key(row, field) do
    case Map.get(row, field) do
      %Decimal{} = d -> Decimal.to_float(d)
      nil -> nil_sentinel(field)
      v -> v
    end
  end

  defp nil_sentinel(field) when field in [:contact_name, :category], do: ""
  defp nil_sentinel(_), do: 0

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  defp default_dir(field) when field in [:contact_name, :category], do: :asc
  defp default_dir(_), do: :desc

  defp sort_arrow(field, sort_by, sort_dir) do
    cond do
      field != sort_by -> ""
      sort_dir == :asc -> " ▲"
      true -> " ▼"
    end
  end

  defp sum_field(rows, field) do
    Enum.reduce(rows, 0, fn r, acc -> acc + to_number(Map.get(r, field)) end)
  end

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(n) when is_number(n), do: n
  defp to_number(_), do: 0

  defp zero?(value), do: to_number(value) == 0

  defp contact_txn_url(company_id, name, oldest_unpaid, t_date) do
    t = to_date_struct(t_date)
    f = to_date_struct(oldest_unpaid) || Date.add(t, -365)

    qry =
      URI.encode_query(%{
        "search[name]" => name,
        "search[f_date]" => Date.to_iso8601(f),
        "search[t_date]" => Date.to_iso8601(t)
      })

    "/companies/#{company_id}/contact_transactions?#{qry}"
  end

  defp to_date_struct(%Date{} = d), do: d
  defp to_date_struct(s) when is_binary(s), do: Date.from_iso8601!(s)
  defp to_date_struct(nil), do: nil

  defp fmt(n), do: Number.Delimit.number_to_delimited(n)

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:bucket_labels, AgingBuckets.bucket_labels(assigns.cutoffs))
      |> assign(:preset_options, AgingBuckets.preset_options())

    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" phx-change="changed" autocomplete="off">
          <div class="grid grid-cols-12 gap-1 tracking-tighter">
            <div class="col-span-2">
              <.input
                name="search[report]"
                id="search_report"
                value={@search.report}
                options={["Debtors Aging", "Creditors Aging"]}
                type="select"
                label={gettext("Report")}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Date")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-2">
              <.input
                name="search[preset]"
                id="search_preset"
                value={@search.preset}
                options={@preset_options}
                type="select"
                label={gettext("Preset")}
              />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input label="P1" name="search[c1]" type="number" id="search_c1" step="1" value={@search.c1} />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input label="P2" name="search[c2]" type="number" id="search_c2" step="1" value={@search.c2} />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input label="P3" name="search[c3]" type="number" id="search_c3" step="1" value={@search.c3} />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input label="P4" name="search[c4]" type="number" id="search_c4" step="1" value={@search.c4} />
            </div>
            <div class="col-span-2 mt-4">
              <.button>
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=aging&rep=#{@search.report}&tdate=#{@search.t_date}&c1=#{@search.c1}&c2=#{@search.c2}&c3=#{@search.c3}&c4=#{@search.c4}"
                }
                target="_blank"
                class="blue button"
              >
                CSV
              </.link>
              <.link
                :if={@can_print and @search.report == "Debtors Aging"}
                class="blue button"
                navigate={
                  ~p"/companies/#{@current_company.id}//Statement/print_multi?&tdate=#{@search.t_date}&ids=#{Enum.join(@selected_ids, ",")}&c1=#{@search.c1}&c2=#{@search.c2}&c3=#{@search.c3}&c4=#{@search.c4}"
                }
                target="_blank"
              >
                Print ({MapSet.size(@selected_ids)})
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% rows = sort_rows(@result.result, @sort_by, @sort_dir) %>
          <% widths = ["4%", "11%", "21%", "8%", "8%", "8%", "8%", "8%", "10%", "10%", "4%"] %>
          <% header_row_class = "font-medium flex flex-row text-center tracking-tighter mb-1" %>
          <% header_col_class = "border rounded bg-gray-200 border-gray-400 px-2 py-1" %>
          <% data_row_class = "flex flex-row text-center tracking-tighter max-h-20" %>
          <% data_col_class = "border rounded bg-blue-200 border-blue-400 px-2 py-1" %>
          <% total_col_class = "border rounded bg-gray-300 border-gray-500 px-2 py-1 font-bold" %>

          <div class={header_row_class}>
            <div class={"w-[#{Enum.at(widths, 0)}] #{header_col_class}"}>
              <input
                :if={@search.report == "Debtors Aging"}
                type="checkbox"
                phx-click="toggle_all"
                checked={MapSet.size(@selected_ids) > 0 and Enum.all?(rows, fn r -> MapSet.member?(@selected_ids, r.contact_id) end)}
              />
            </div>
            <div
              :for={{label, field, w} <- [
                {gettext("Category"), :category, Enum.at(widths, 1)},
                {gettext("Account"), :contact_name, Enum.at(widths, 2)},
                {Enum.at(@bucket_labels, 0), :p1, Enum.at(widths, 3)},
                {Enum.at(@bucket_labels, 1), :p2, Enum.at(widths, 4)},
                {Enum.at(@bucket_labels, 2), :p3, Enum.at(widths, 5)},
                {Enum.at(@bucket_labels, 3), :p4, Enum.at(widths, 6)},
                {Enum.at(@bucket_labels, 4), :p5, Enum.at(widths, 7)},
                {gettext("Total"), :total, Enum.at(widths, 8)},
                {gettext("PD Amt"), :pd_amt, Enum.at(widths, 9)},
                {gettext("Chqs"), :pd_chqs, Enum.at(widths, 10)}
              ]}
              class={"w-[#{w}] #{header_col_class} cursor-pointer hover:bg-gray-300"}
              phx-click="sort"
              phx-value-field={field}
              title="Click to sort"
            >
              {label}{sort_arrow(field, @sort_by, @sort_dir)}
            </div>
          </div>

          <% num_class = data_col_class <> " text-right tabular-nums" %>
          <% num_drill_class = num_class <> " cursor-pointer hover:bg-gray-400" %>
          <% num_total_class = total_col_class <> " text-right tabular-nums" %>

          <div :for={d <- rows} class={data_row_class}>
            <div class={"w-[#{Enum.at(widths, 0)}] #{data_col_class}"}>
              <input
                :if={@search.report == "Debtors Aging"}
                type="checkbox"
                phx-click="toggle_select"
                phx-value-id={d.contact_id}
                checked={MapSet.member?(@selected_ids, d.contact_id)}
              />
            </div>
            <div class={"w-[#{Enum.at(widths, 1)}] #{data_col_class}"}>{d.category}</div>
            <div class={"w-[#{Enum.at(widths, 2)}] #{data_col_class} text-left"}>
              <.link
                navigate={contact_txn_url(@current_company.id, d.contact_name, d.oldest_unpaid, @search.t_date)}
                target="_blank"
                class="text-blue-700 dark:text-blue-300 hover:underline"
              >
                {d.contact_name}
              </.link>
            </div>
            <div
              :for={{bucket, value, w} <- [
                {"p1", d.p1, Enum.at(widths, 3)},
                {"p2", d.p2, Enum.at(widths, 4)},
                {"p3", d.p3, Enum.at(widths, 5)},
                {"p4", d.p4, Enum.at(widths, 6)},
                {"p5", d.p5, Enum.at(widths, 7)}
              ]}
              class={"w-[#{w}] #{if zero?(value), do: num_class, else: num_drill_class}"}
              phx-click={if zero?(value), do: nil, else: "drill"}
              phx-value-contact_id={d.contact_id}
              phx-value-bucket={bucket}
              phx-value-name={d.contact_name}
              title={if zero?(value), do: nil, else: "Click to see transactions in this bucket"}
            >
              {fmt(value)}
            </div>
            <div class={"w-[#{Enum.at(widths, 8)}] #{num_class} font-bold"}>{fmt(d.total)}</div>
            <div class={"w-[#{Enum.at(widths, 9)}] #{num_class}"}>{fmt(d.pd_amt)}</div>
            <div class={"w-[#{Enum.at(widths, 10)}] #{num_class}"}>{d.pd_chqs}</div>
          </div>

          <div :if={rows != []} class={data_row_class}>
            <div class={"w-[#{Enum.at(widths, 0)}] #{total_col_class}"}></div>
            <div class={"w-[#{Enum.at(widths, 1)}] #{total_col_class}"}></div>
            <div class={"w-[#{Enum.at(widths, 2)}] #{total_col_class} text-right"}>{gettext("Totals")}</div>
            <div class={"w-[#{Enum.at(widths, 3)}] #{num_total_class}"}>{fmt(sum_field(rows, :p1))}</div>
            <div class={"w-[#{Enum.at(widths, 4)}] #{num_total_class}"}>{fmt(sum_field(rows, :p2))}</div>
            <div class={"w-[#{Enum.at(widths, 5)}] #{num_total_class}"}>{fmt(sum_field(rows, :p3))}</div>
            <div class={"w-[#{Enum.at(widths, 6)}] #{num_total_class}"}>{fmt(sum_field(rows, :p4))}</div>
            <div class={"w-[#{Enum.at(widths, 7)}] #{num_total_class}"}>{fmt(sum_field(rows, :p5))}</div>
            <div class={"w-[#{Enum.at(widths, 8)}] #{num_total_class}"}>{fmt(sum_field(rows, :total))}</div>
            <div class={"w-[#{Enum.at(widths, 9)}] #{num_total_class}"}>{fmt(sum_field(rows, :pd_amt))}</div>
            <div class={"w-[#{Enum.at(widths, 10)}] #{num_total_class}"}>{sum_field(rows, :pd_chqs) |> trunc()}</div>
          </div>

          <div class="mb-10" />
        </:result_html>
      </.async_html>

      <.modal :if={@drill} id="drill-modal" show on_cancel={JS.push("close_drill")} max_w="max-w-4xl">
        <:title>
          {@drill.contact_name} — {@drill.bucket_label} days
        </:title>
        <div class="mt-4">
          <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
            <div class="w-[15%] border rounded bg-gray-200 border-gray-400 px-2 py-1">Date</div>
            <div class="w-[15%] border rounded bg-gray-200 border-gray-400 px-2 py-1">Doc Type</div>
            <div class="w-[18%] border rounded bg-gray-200 border-gray-400 px-2 py-1">Doc No</div>
            <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">Age</div>
            <div class="w-[20%] border rounded bg-gray-200 border-gray-400 px-2 py-1 text-right">Balance</div>
          </div>
          <div :if={@drill.rows == []} class="text-center italic text-zinc-500 py-4">
            No transactions in this bucket.
          </div>
          <div :for={t <- @drill.rows} class="flex flex-row tracking-tighter">
            <div class="w-[15%] border rounded bg-blue-50 border-blue-200 px-2 py-1">{t.doc_date}</div>
            <div class="w-[15%] border rounded bg-blue-50 border-blue-200 px-2 py-1">{t.doc_type}</div>
            <div class="w-[18%] border rounded bg-blue-50 border-blue-200 px-2 py-1">{t.doc_no}</div>
            <div class="w-[10%] border rounded bg-blue-50 border-blue-200 px-2 py-1 text-right tabular-nums">{t.age_days}</div>
            <div class="w-[20%] border rounded bg-blue-50 border-blue-200 px-2 py-1 text-right tabular-nums">{fmt(t.balance)}</div>
          </div>
          <div :if={@drill.rows != []} class="flex flex-row tracking-tighter mt-1">
            <div class="w-[58%] border rounded bg-gray-300 border-gray-500 px-2 py-1 text-right font-bold">Total</div>
            <div class="w-[20%] border rounded bg-gray-300 border-gray-500 px-2 py-1 text-right tabular-nums font-bold">
              {fmt(sum_field(@drill.rows, :balance))}
            </div>
          </div>
        </div>
      </.modal>
    </div>
    """
  end
end
