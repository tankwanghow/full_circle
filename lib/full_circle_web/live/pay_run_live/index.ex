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
  def handle_event("prev", _, socket), do: {:noreply, shift_to(socket, -1)}

  @impl true
  def handle_event("next", _, socket), do: {:noreply, shift_to(socket, 1)}

  @impl true
  def handle_event("current", _, socket) do
    d = Timex.today() |> Timex.shift(months: -1)
    {:noreply, navigate_to(socket, d.month, d.year)}
  end

  defp shift_to(socket, months) do
    d =
      Timex.end_of_month(socket.assigns.search.year, socket.assigns.search.month)
      |> Timex.shift(months: months)

    navigate_to(socket, d.month, d.year)
  end

  defp navigate_to(socket, month, year) do
    qry = %{"search[month]" => month, "search[year]" => year}
    push_navigate(socket, to: "/companies/#{socket.assigns.current_company.id}/PayRun?#{URI.encode_query(qry)}")
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    d = Timex.today() |> Timex.shift(months: -1)

    month = String.to_integer(params["month"] || "#{d.month}")
    year = String.to_integer(params["year"] || "#{d.year}")

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

  # [latest, previous] — matches pay_run_index ordering (latest month first/leftmost).
  defp window_months(month, year) do
    [0, -1]
    |> Enum.map(fn x -> Timex.end_of_month(year, month) |> Timex.shift(months: x) end)
    |> Enum.map(fn d -> {d.year, d.month} end)
  end

  defp month_label({yr, mth}), do: "#{Timex.month_shortname(mth)} #{yr}"

  defp fmt(d), do: Number.Delimit.number_to_delimited(d)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-9/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <div class="flex justify-center items-center gap-2 mb-2">
        <.button phx-click="prev" class="h-9">◀</.button>
        <div class="font-semibold text-lg w-48 text-center">
          {month_label(Enum.at(@months, 0))} – {month_label(Enum.at(@months, 1))}
        </div>
        <.button phx-click="next" class="h-9">▶</.button>
        <.button phx-click="current" class="h-9 gray">{gettext("Current")}</.button>

        <.link
          :if={@can_print}
          navigate={~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=false&ids=#{@ids}"}
          target="_blank"
          class="blue button"
        >
          {gettext("Print")}{"(#{Enum.count(@selected)})"}
        </.link>
        <.link
          :if={@can_print}
          navigate={~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=true&ids=#{@ids}"}
          target="_blank"
          class="blue button"
        >
          {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
        </.link>
      </div>

      <div :if={Enum.count(@objects) > 0} class="mb-2">
        <%= for ym <- @months do %>
          <div class="text-center text-sm bg-amber-100 border border-amber-300">
            <span class="font-bold">{month_label(ym)}</span>
            · {gettext("Done")} {@totals[ym].done}
            · {gettext("Pending")} {@totals[ym].pending}
            · {gettext("Payroll")} {fmt(@totals[ym].payroll)}
          </div>
        <% end %>
      </div>

      <div :if={Enum.count(@objects) > 0} class="flex bg-amber-200 text-center font-bold">
        <div class="w-[16%] border border-rose-400">{gettext("Name")}</div>
        <div :for={ym <- @months} class="w-[42%] border border-rose-400">{month_label(ym)}</div>
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

      <div :if={Enum.count(@objects) > 0} class="flex bg-amber-200 text-center font-bold">
        <div class="w-[16%] border border-rose-400">{gettext("Total")}</div>
        <div :for={ym <- @months} class="w-[42%] border border-rose-400">{fmt(@totals[ym].payroll)}</div>
      </div>
    </div>
    """
  end
end
