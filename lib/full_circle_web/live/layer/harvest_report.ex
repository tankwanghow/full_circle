defmodule FullCircleWeb.LayerLive.HarvestReport do
  use FullCircleWeb, :live_view

  alias FullCircle.{Layer}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    t_date = params["t_date"] || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
     |> assign(page_title: "Harvest Report for #{t_date}")
     |> assign(search: %{t_date: t_date})
     |> filter_transactions(t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/harvest_report?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  @impl true
  def handle_event(
        "changed",
        %{
          "search" => %{
            "t_date" => t_date
          }
        },
        socket
      ) do
    t_date = t_date || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
     |> assign(page_title: "Harvest Report for #{t_date}")
     |> assign(search: %{t_date: t_date})
     |> assign(objects_count: 0)
     |> assign(objects: [])}
  end

  defp filter_transactions(socket, t_date) do
    objects =
      if t_date == "" do
        []
      else
        t_date = t_date |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

        Layer.harvest_report(
          t_date,
          socket.assigns.current_company.id
        )
      end

      # objects =
      #   objects
      #   |> Enum.filter(fn x ->
      #     x.yield_0 + x.yield_1 + x.yield_2 + x.yield_3 + x.yield_4 + x.yield_5 + x.yield_6 +
      #       x.yield_7 > 0
      #   end)

    socket
    |> assign(objects_count: Enum.count(objects))
    |> assign(objects: objects)
  end

  defp yield_color(y1, y2) do
    cond do
      y1 - y2 > -0.02 -> "bg-green-200 border-green-400"
      y1 - y2 <= -0.02 -> "bg-rose-200 border-rose-400"
    end
  end

  defp yield_header(dt, days) do
    try do
      dt
      |> Timex.parse!("{YYYY}-{0M}-{0D}")
      |> Timex.shift(days: days)
      |> Timex.format!("%d/%m", :strftime)
    rescue
      Timex.Parse.ParseError ->
        "error"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-change="changed" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-2">
              <.input
                label={gettext("To")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-2 mt-6">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@objects_count > 0}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/harvrepo?tdate=#{@search.t_date}"
                }
                target="_blank"
              >
                Print
              </.link>

              <.link
                :if={@objects_count > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=harvrepo&tdate=#{@search.t_date}"
                }
                target="_blank"
                class="blue button"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <%= FullCircleWeb.CsvHtml.headers(
        [
          gettext("House"),
          gettext("Collector"),
          gettext("Age"),
          gettext("Production"),
          gettext("Death"),
          yield_header(@search.t_date, 0),
          yield_header(@search.t_date, -1),
          yield_header(@search.t_date, -2),
          yield_header(@search.t_date, -3),
          yield_header(@search.t_date, -4),
          yield_header(@search.t_date, -5),
          yield_header(@search.t_date, -6),
          yield_header(@search.t_date, -7)
        ],
        "font-medium flex flex-row text-center tracking-tighter mb-1",
        ~w(6% 20% 6% 7% 5% 7% 7% 7% 7% 7% 7% 7% 7%),
        "border rounded bg-gray-200 border-gray-400 px-2 py-1",
        assigns
      ) %>

      <div id="lists">
        <%= for obj <- @objects do %>
          <div class="flex flex-row text-center tracking-tighter max-h-20">
            <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.house_no %>
            </div>
            <div class="w-[20%] border rounded bg-blue-200 border-blue-400 px-2 py-1 overflow-clip">
              <%= obj.employee %>
            </div>
            <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.age %>
            </div>
            <div class="w-[7%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= (obj.prod / 30) |> trunc %>
            </div>
            <div class="w-[5%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.dea %>
            </div>
            <div class={[
              "w-[7%] border rounded px-2 py-1",
              yield_color(obj.yield_0, obj.yield_1)
            ]}>
              <%= (obj.yield_0 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
            <div class={[
              "w-[7%] border rounded px-2 py-1",
              yield_color(obj.yield_1, obj.yield_2)
            ]}>
              <%= (obj.yield_1 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
            <div class={[
              "w-[7%] border rounded px-2 py-1",
              yield_color(obj.yield_2, obj.yield_3)
            ]}>
              <%= (obj.yield_2 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
            <div class={[
              "w-[7%] border rounded px-2 py-1",
              yield_color(obj.yield_3, obj.yield_4)
            ]}>
              <%= (obj.yield_3 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
            <div class={[
              "w-[7%] border rounded px-2 py-1",
              yield_color(obj.yield_4, obj.yield_5)
            ]}>
              <%= (obj.yield_4 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
            <div class={[
              "w-[7%] border rounded px-2 py-1",
              yield_color(obj.yield_5, obj.yield_6)
            ]}>
              <%= (obj.yield_5 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
            <div class={[
              "w-[7%] border rounded px-2 py-1",
              yield_color(obj.yield_6, obj.yield_7)
            ]}>
              <%= (obj.yield_6 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
            <div class="w-[7%] border rounded bg-green-200 border-green-400 px-2 py-1">
              <%= (obj.yield_7 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
            </div>
          </div>
        <% end %>
      </div>
      <div :if={@objects_count > 0} id="footer">
        <div class="flex flex-row text-center font-bold tracking-tighter mb-5 mt-1">
          <div class="w-[26%] border rounded bg-amber-200 border-amber-400 px-2 py-1 overflow-clip">
          </div>
          <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
            <%= ((@objects |> Enum.reduce(0, fn e, acc -> acc + e.age end)) / Enum.count(@objects))
            |> trunc %>
          </div>
          <div class="w-[7%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
            <%= ((@objects |> Enum.reduce(0, fn e, acc -> acc + e.prod end)) / 30) |> trunc %>
          </div>
          <div class="w-[5%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
            <%= @objects |> Enum.reduce(0, fn e, acc -> acc + e.dea end) %>
          </div>
          <div class="w-[56%] border rounded bg-amber-200 border-amber-400 px-2 py-1"></div>
        </div>
      </div>
    </div>
    """
  end
end
