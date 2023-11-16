defmodule FullCircleWeb.PayRunLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.PayRun
  alias FullCircleWeb.PayRunLive.IndexComponent

  @selected_max 30

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Pay Run"))
      |> assign(objects: [])

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "month" => month,
            "year" => year
          }
        },
        socket
      ) do
    qry = %{
      "search[month]" => month,
      "search[year]" => year
    }

    url = "/companies/#{socket.assigns.current_company.id}/PayRun?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
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
  def handle_params(params, _uri, socket) do
    params = params["search"]

    month =
      String.to_integer(params["month"] || "#{(Timex.today() |> Timex.shift(months: -1)).month}")

    year = String.to_integer(params["year"] || "#{Timex.today().year}")

    {:noreply,
     socket
     |> assign(search: %{month: month, year: year})
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> filter_objects(month, year)}
  end

  defp filter_objects(socket, month, year) do
    objects = PayRun.pay_run_index(month, year, socket.assigns.current_company)

    socket |> assign(objects: objects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-7/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form
          for={%{}}
          id="search-form"
          phx-submit="search"
          autocomplete="off"
          class="mx-auto w-11/12 mb-2"
        >
          <div class=" flex flex-row gap-1 justify-center">
            <div class="w-[11%]">
              <.input
                min="1"
                max="12"
                name="search[month]"
                type="number"
                value={@search.month}
                id="search_month"
                label={gettext("Month")}
              />
            </div>
            <div class="w-[11%]">
              <.input
                min="2000"
                max="2099"
                name="search[year]"
                type="number"
                value={@search.year}
                id="search_year"
                label={gettext("Year")}
              />
            </div>
            <.button class="w-[7%] mt-5 h-10 grow-0 shrink-0">🔍</.button>
            <div class="text-center mt-7">
              <.link
                :if={@can_print}
                navigate={
                  ~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=false&ids=#{@ids}"
                }
                target="_blank"
                class="blue button"
              >
                <%= gettext("Print") %>
              </.link>
              <.link
                :if={@can_print}
                navigate={
                  ~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=true&ids=#{@ids}"
                }
                target="_blank"
                class="blue button"
              >
                <%= gettext("Pre Print") %>
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <div :if={Enum.count(@objects) > 0} class="flex bg-amber-200 text-center font-bold">
        <div class="w-[30%] border border-rose-400">Name</div>
        <%= for ym <- Enum.at(@objects, 1).pay_list |> Enum.map(fn {_,_,y,m} -> "#{m}/#{y}" end) do %>
          <div class="border border-rose-400 w-[23.333%]"><%= ym %></div>
        <% end %>
      </div>

      <div
        :if={Enum.count(@objects) == 0}
        class="bg-amber-200 text-3xl p-4 rounded text-center font-bold"
      >
        No Data.....
      </div>

      <div id="objects_list" class="mb-5">
        <%= for obj <- @objects do %>
          <.live_component
            module={IndexComponent}
            id={obj.id}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>
    </div>
    """
  end
end
