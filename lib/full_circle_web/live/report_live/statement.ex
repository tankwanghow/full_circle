defmodule FullCircleWeb.ReportLive.Statement do
  use FullCircleWeb, :live_view

  alias FullCircle.{Reporting}
  alias FullCircle.Reporting.AgingBuckets
  alias FullCircleWeb.ReportLive.StatementComponent

  @selected_max 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Contacts Balance")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"] || %{}

    gt = params["gt"] || "0.00"

    t_date = params["t_date"] || Timex.today()

    cutoffs = AgingBuckets.parse_cutoffs(params)
    preset = AgingBuckets.preset_for(cutoffs)

    search = %{
      gt: gt,
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
     |> query(gt, t_date)
     |> assign(can_print: false)
     |> assign(selected: [])}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj = Enum.find(socket.assigns.objects, fn x -> x.id == id end)

    Phoenix.LiveView.send_update(
      self(),
      StatementComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: true})}]
    )

    socket =
      socket
      |> assign(selected: [id | socket.assigns.selected])
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    obj = Enum.find(socket.assigns.objects, fn x -> x.id == id end)

    Phoenix.LiveView.send_update(
      self(),
      StatementComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: false})}]
    )

    socket =
      socket
      |> assign(selected: Enum.reject(socket.assigns.selected, fn sid -> sid == id end))
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
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

    {:noreply, socket |> assign(search: search, selected: [], objects: [])}
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

    {:noreply, socket |> assign(search: search, selected: [], objects: [])}
  end

  def handle_event("changed", _, socket) do
    {:noreply,
     socket
     |> assign(selected: [])
     |> assign(objects: [])}
  end

  @impl true
  def handle_event("query", %{"search" => params}, socket) do
    cutoffs = AgingBuckets.parse_cutoffs(params)

    qry = %{
      "search[gt]" => params["gt"],
      "search[t_date]" => params["t_date"],
      "search[c1]" => Enum.at(cutoffs, 0),
      "search[c2]" => Enum.at(cutoffs, 1),
      "search[c3]" => Enum.at(cutoffs, 2),
      "search[c4]" => Enum.at(cutoffs, 3)
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/debtor_statement?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp query(socket, gt, t_date) do
    objects =
      if gt == "" or t_date == "" do
        []
      else
        Reporting.debtors_balance(Decimal.new(gt), t_date, socket.assigns.current_company)
      end

    socket
    |> assign(objects: objects)
    |> assign(objects_count: Enum.count(objects))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :preset_options, AgingBuckets.preset_options())

    ~H"""
    <div class="w-6/12 mx-auto mb-8">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" phx-change="changed" autocomplete="off">
          <div class="grid grid-cols-13 gap-1 tracking-tighter">
            <div class="col-span-1">
              <.input
                label={gettext("Bal >")}
                id="search_gt"
                name="search[gt]"
                value={@search.gt}
                type="number"
                step="0.01"
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("To")}
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
                label={gettext("Aging Preset")}
              />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input
                label="P1"
                name="search[c1]"
                type="number"
                id="search_c1"
                step="1"
                value={@search.c1}
              />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input
                label="P2"
                name="search[c2]"
                type="number"
                id="search_c2"
                step="1"
                value={@search.c2}
              />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input
                label="P3"
                name="search[c3]"
                type="number"
                id="search_c3"
                step="1"
                value={@search.c3}
              />
            </div>
            <div :if={@search.preset == "Custom"} class="col-span-1">
              <.input
                label="P4"
                name="search[c4]"
                type="number"
                id="search_c4"
                step="1"
                value={@search.c4}
              />
            </div>
            <div class="col-span-4 mt-4">
              <.button>
                {gettext("Query")}
              </.button>
              <.link
                :if={@can_print}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}//Statement/print_multi?&tdate=#{@search.t_date}&ids=#{@ids}&c1=#{@search.c1}&c2=#{@search.c2}&c3=#{@search.c3}&c4=#{@search.c4}"
                }
                target="_blank"
              >
                Print {"(#{Enum.count(@selected)})"}
              </.link>
            </div>
          </div>
        </.form>
      </div>

      {FullCircleWeb.CsvHtml.headers(
        [
          gettext("Print"),
          gettext("Account"),
          gettext("Balance"),
          gettext("PD Chqs"),
          gettext("PD Chqs Amt"),
          gettext("Actual")
        ],
        "font-medium flex flex-row text-center tracking-tighter mb-1",
        ["6%", "47%", "13%", "8%", "13%", "13%"],
        "border rounded bg-gray-200 border-gray-400 px-2 py-1",
        assigns
      )}

      <%= for obj <- @objects do %>
        <.live_component
          current_company={@current_company}
          module={StatementComponent}
          id={"#{obj.id}"}
          obj={obj}
          ex_class=""
        />
      <% end %>
    </div>
    """
  end
end
