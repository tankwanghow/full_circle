defmodule FullCircleWeb.PayRunLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.PayRun
  alias FullCircleWeb.PayRunLive.IndexComponent

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
  def handle_params(params, _uri, socket) do
    params = params["search"]

    month = String.to_integer(params["month"] || "#{Timex.today().month}")
    year = String.to_integer(params["year"] || "#{Timex.today().year}")

    {:noreply,
     socket
     |> assign(search: %{month: month, year: year})
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
          </div>
        </.form>
      </div>

      <div class="flex bg-amber-200 text-center font-bold">
        <div class="w-[30%] border-y-2 border-x border-amber-600">Name</div>
        <%= for ym <- Enum.at(@objects, 1).pay_list |> Enum.map(fn {_,_,y,m} -> "#{m}/#{y}" end) do %>
          <div class="border-y-2 border-r border-amber-600 w-[23.3%]"><%= ym %></div>
        <% end %>
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
