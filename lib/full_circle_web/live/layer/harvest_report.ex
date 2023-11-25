defmodule FullCircleWeb.LayerLive.HarvestReport do
  use FullCircleWeb, :live_view

  alias FullCircle.{Layer}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Harvest Report")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    t_date = params["t_date"] || Timex.today |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
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
     |> push_patch(to: url)}
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

    socket
    |> assign(objects_count: Enum.count(objects))
    |> assign(objects: objects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
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
                  ~p"/companies/#{@current_company.id}/print_harvest_report?report=harvrepo&tdate=#{@search.t_date}"
                }
                target="_blank"
              >
                Print
              </.link>

              <.link
                :if={@objects_count > 0}
                href={
                  ~p"/companies/#{@current_company.id}/csv?report=harvrepo&tdate=#{@search.t_date}"
                }
                class="blue button"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
        <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("House") %>
        </div>
        <div class="w-[20%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Collector") %>
        </div>
        <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Age") %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Production") %>
        </div>
        <div class="w-[5%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Death") %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date |> Timex.parse!("{YYYY}-{0M}-{0D}") |> Timex.format!("%d/%m", :strftime) %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date
          |> Timex.parse!("{YYYY}-{0M}-{0D}")
          |> Timex.shift(days: -1)
          |> Timex.format!("%d/%m", :strftime) %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date
          |> Timex.parse!("{YYYY}-{0M}-{0D}")
          |> Timex.shift(days: -2)
          |> Timex.format!("%d/%m", :strftime) %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date
          |> Timex.parse!("{YYYY}-{0M}-{0D}")
          |> Timex.shift(days: -3)
          |> Timex.format!("%d/%m", :strftime) %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date
          |> Timex.parse!("{YYYY}-{0M}-{0D}")
          |> Timex.shift(days: -4)
          |> Timex.format!("%d/%m", :strftime) %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date
          |> Timex.parse!("{YYYY}-{0M}-{0D}")
          |> Timex.shift(days: -5)
          |> Timex.format!("%d/%m", :strftime) %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date
          |> Timex.parse!("{YYYY}-{0M}-{0D}")
          |> Timex.shift(days: -6)
          |> Timex.format!("%d/%m", :strftime) %>
        </div>
        <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= @search.t_date
          |> Timex.parse!("{YYYY}-{0M}-{0D}")
          |> Timex.shift(days: -7)
          |> Timex.format!("%d/%m", :strftime) %>
        </div>
      </div>
      <div class=" bg-gray-50">
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
                obj.yield_0 - obj.yield_1 > -0.02 && "bg-green-200 border-green-400",
                obj.yield_0 - obj.yield_1 <= -0.02 && "bg-rose-200 border-rose-400"
              ]}>
                <%= (obj.yield_0 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
              <div class={[
                "w-[7%] border rounded px-2 py-1",
                obj.yield_1 - obj.yield_2 > -0.02 && "bg-green-200 border-green-400",
                obj.yield_1 - obj.yield_2 <= -0.02 && "bg-rose-200 border-rose-400"
              ]}>
                <%= (obj.yield_1 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
              <div class={[
                "w-[7%] border rounded px-2 py-1",
                obj.yield_2 - obj.yield_3 > -0.02 && "bg-green-200 border-green-400",
                obj.yield_2 - obj.yield_3 <= -0.02 && "bg-rose-200 border-rose-400"
              ]}>
                <%= (obj.yield_2 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
              <div class={[
                "w-[7%] border rounded px-2 py-1",
                obj.yield_3 - obj.yield_4 > -0.02 && "bg-green-200 border-green-400",
                obj.yield_3 - obj.yield_4 <= -0.02 && "bg-rose-200 border-rose-400"
              ]}>
                <%= (obj.yield_3 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
              <div class={[
                "w-[7%] border rounded px-2 py-1",
                obj.yield_4 - obj.yield_5 > -0.02 && "bg-green-200 border-green-400",
                obj.yield_4 - obj.yield_5 <= -0.02 && "bg-rose-200 border-rose-400"
              ]}>
                <%= (obj.yield_4 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
              <div class={[
                "w-[7%] border rounded px-2 py-1",
                obj.yield_5 - obj.yield_6 > -0.02 && "bg-green-200 border-green-400",
                obj.yield_5 - obj.yield_6 <= -0.02 && "bg-rose-200 border-rose-400"
              ]}>
                <%= (obj.yield_5 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
              <div class={[
                "w-[7%] border rounded px-2 py-1",
                obj.yield_6 - obj.yield_7 > -0.02 && "bg-green-200 border-green-400",
                obj.yield_6 - obj.yield_7 <= -0.02 && "bg-rose-200 border-rose-400"
              ]}>
                <%= (obj.yield_6 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
              <div class="w-[7%] border rounded bg-green-200 border-green-400 px-2 py-1">
                <%= (obj.yield_7 * 100) |> Number.Percentage.number_to_percentage(precision: 1) %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      <div id="footer">
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
