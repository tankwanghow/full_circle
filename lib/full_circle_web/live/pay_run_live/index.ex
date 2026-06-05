defmodule FullCircleWeb.PayRunLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.PayRun
  alias FullCircleWeb.PayRunLive.IndexComponent

  @selected_max 15

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Pay Run"))
     |> assign(objects: [])}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    socket =
      socket
      |> assign(selected: [id | socket.assigns.selected])
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    socket =
      socket
      |> assign(selected: Enum.reject(socket.assigns.selected, fn sid -> sid == id end))
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("goto_month", %{"month" => m, "year" => y}, socket) do
    {:noreply, navigate_to(socket, String.to_integer(m), String.to_integer(y))}
  end

  @impl true
  def handle_event("current", _, socket) do
    {m, y} = default_base()
    {:noreply, navigate_to(socket, m, y)}
  end

  defp navigate_to(socket, month, year) do
    {month, year} = clamp_base(month, year)
    qry = %{"search[month]" => month, "search[year]" => year}

    push_navigate(socket,
      to: "/companies/#{socket.assigns.current_company.id}/PayRun?#{URI.encode_query(qry)}"
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    {def_m, def_y} = default_base()

    month = String.to_integer(params["month"] || "#{def_m}")
    year = String.to_integer(params["year"] || "#{def_y}")
    {month, year} = clamp_base(month, year)

    objects = PayRun.pay_run_index(month, year, socket.assigns.current_company)

    {:noreply,
     socket
     |> assign(search: %{month: month, year: year})
     |> assign(objects: objects)
     |> assign(totals: PayRun.pay_run_totals(objects))
     |> assign(months: window_months(month, year))
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)}
  end

  # Default/"Current" base = the current pay month (one month in arrears).
  defp default_base do
    d = Timex.today() |> Timex.shift(months: -1)
    {d.month, d.year}
  end

  # The window's newest month may not exceed current pay month + 1 (next month).
  defp clamp_base(month, year) do
    max_d = Timex.today() |> Timex.beginning_of_month()
    req_d = Date.new!(year, month, 1)

    if Date.compare(req_d, max_d) == :gt do
      {max_d.month, max_d.year}
    else
      {month, year}
    end
  end

  # Three months, latest first — matches pay_run_index ordering (latest month leftmost).
  defp window_months(month, year) do
    [0, -1, -2]
    |> Enum.map(fn x -> Timex.end_of_month(year, month) |> Timex.shift(months: x) end)
    |> Enum.map(fn d -> {d.year, d.month} end)
  end

  defp month_label({yr, mth}), do: "#{Timex.month_shortname(mth)} #{yr}"

  defp totals_for(totals, ym),
    do: Map.get(totals, ym, %{done: 0, pending: 0, payroll: Decimal.new(0)})

  # Current (newest) month is wide — it carries unprocessed notes/advances; older months are tight.
  defp col_class(0), do: "w-[40%]"
  defp col_class(_), do: "w-[22%]"

  defp fmt(d), do: Number.Delimit.number_to_delimited(d)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-9/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <div class="flex flex-wrap justify-center items-stretch gap-2 mb-2">
        <.button
          :for={ym <- @months}
          phx-click="goto_month"
          phx-value-month={elem(ym, 1)}
          phx-value-year={elem(ym, 0)}
          class={
            "grow basis-0 h-auto py-1 text-sm leading-tight whitespace-normal" <>
              if(ym == hd(@months), do: " ring-2 ring-blue-600", else: "")
          }
        >
          <span class="font-bold">{month_label(ym)}</span>
          <br />{gettext("Done")} {totals_for(@totals, ym).done} · {gettext("Pending")} {totals_for(
            @totals,
            ym
          ).pending} · {fmt(totals_for(@totals, ym).payroll)}
        </.button>
        <.button phx-click="current" class="grow-0 gray h-auto py-1">{gettext("Current")}</.button>
      </div>

      <div :if={@can_print} class="flex justify-center gap-2 mb-2">
        <.link
          navigate={
            ~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=false&ids=#{@ids}"
          }
          target="_blank"
          class="blue button"
        >
          {gettext("Print")}{"(#{Enum.count(@selected)})"}
        </.link>
        <.link
          navigate={
            ~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=true&ids=#{@ids}"
          }
          target="_blank"
          class="blue button"
        >
          {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
        </.link>
      </div>

      <div :if={Enum.count(@objects) > 0} class="flex bg-amber-200 text-center font-bold">
        <div class="w-[16%] border border-rose-400">{gettext("Name")}</div>
        <%= for {ym, idx} <- Enum.with_index(@months) do %>
          <div class={[col_class(idx), "border border-rose-400"]}>{month_label(ym)}</div>
        <% end %>
      </div>

      <div
        :if={Enum.count(@objects) == 0}
        class="bg-amber-200 text-3xl p-4 rounded text-center font-bold"
      >
        {gettext("No Data")}.....
      </div>

      <div id="objects_list" class="mb-2">
        <.live_component
          :for={obj <- @objects}
          module={IndexComponent}
          id={obj.id}
          obj={obj}
          company={@current_company}
          ex_class=""
        />
      </div>
    </div>
    """
  end
end
