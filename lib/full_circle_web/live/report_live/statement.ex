defmodule FullCircleWeb.ReportLive.Statement do
  use FullCircleWeb, :live_view

  alias FullCircle.{Reporting}
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
    params = params["search"]

    gt = params["gt"] || "0.00"

    f_date =
      params["f_date"] ||
        Timex.shift(Timex.today(), months: -1) |> Timex.format!("%Y-%m-%d", :strftime)

    t_date = params["t_date"] || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
     |> assign(search: %{gt: gt, f_date: f_date, t_date: t_date})
     |> query(gt, f_date, t_date)
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
  def handle_event("changed", _, socket) do
    {:noreply,
     socket
     |> assign(selected: [])
     |> assign(objects: [])}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "gt" => gt,
            "f_date" => f_date,
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[gt]" => gt,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/debtor_statement?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp query(socket, gt, f_date, t_date) do
    objects =
      if gt == "" or f_date == "" or t_date == "" do
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
    ~H"""
    <div class="w-6/12 mx-auto mb-8">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" phx-change="changed" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-3">
              <.input
                label={gettext("Balance Greater Than")}
                id="search_gt"
                name="search[gt]"
                value={@search.gt}
                type="number"
                step="0.01"
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
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
            <div class="col-span-5 mt-6">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@can_print}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}//Statement/print_multi?&fdate=#{@search.f_date}&tdate=#{@search.t_date}&ids=#{@ids}"
                }
                target="_blank"
              >
                Print <%= "(#{Enum.count(@selected)})" %>
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <%= FullCircleWeb.CsvHtml.headers(
        [
          gettext("Print"),
          gettext("Account"),
          gettext("Balance")
        ],
        "font-medium flex flex-row text-center tracking-tighter mb-1",
        ["10%", "60%", "30%"],
        "border rounded bg-gray-200 border-gray-400 px-2 py-1",
        assigns
      ) %>

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
