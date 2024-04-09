defmodule FullCircleWeb.ReportLive.FixedAssets do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Fixed Assets")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    t_date = params["t_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{t_date: t_date})
     |> filter_transactions(t_date)}
  end

  @impl true
  def handle_event("query", %{"search" => %{"t_date" => t_date}}, socket) do
    qry = %{"search[t_date]" => t_date}

    url =
      "/companies/#{socket.assigns.current_company.id}/fixed_assets_report?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, t_date) do
    current_company = socket.assigns.current_company

    [y, m, d] =
      try do
        t_date |> String.split("-") |> Enum.map(fn x -> String.to_integer(x) end)
      rescue
        _e ->
          [0, 0, 0]
      end

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             if [y, m, d] == [0, 0, 0] do
               {[], []}
             else
               FullCircle.Reporting.fixed_assets(
                 Date.new!(y, m, d),
                 current_company
               )
             end
         }}
      end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-3">
              <.input
                label={gettext("Date")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-4 mt-6">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@result.result != {[], []} and @result.result}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=fixed_assets_report&tdate=#{@search.t_date}"
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

      <.async_html result={@result}>
        <:result_html>
          <% {col, row} = @result.result %>
          <div :if={Enum.count(col) > 0} class="flex flex-row">
            <%= for h <- col do %>
              <div class={"w-[#{trunc(Float.ceil(100/Enum.count(col)))}%] text-center font-bold border rounded bg-gray-200 border-gray-500"}>
                <%= h %>
              </div>
            <% end %>
          </div>

          <%= for r <- row do %>
            <div class="flex flex-row">
              <%= for c <- r do %>
                <div class={"w-[#{trunc(Float.ceil(100/Enum.count(col)))}%] text-center border rounded bg-blue-200 border-blue-500"}>
                  <%= c %>
                </div>
              <% end %>
            </div>
          <% end %>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
