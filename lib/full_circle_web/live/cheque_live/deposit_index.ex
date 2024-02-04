defmodule FullCircleWeb.ChequeLive.DepositIndex do
  use FullCircleWeb, :live_view

  alias FullCircle.{Cheque}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Deposits")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""
    d_date = params["d_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, d_date: d_date})
     |> filter_objects(terms, true, d_date, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.d_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "terms" => terms,
            "d_date" => d_date
          }
        },
        socket
      ) do
    socket =
      socket
      |> assign(search: %{terms: terms, d_date: d_date})

    {:noreply,
     socket
     |> push_navigate(to: url_from_search(socket))}
  end

  defp filter_objects(socket, terms, reset, d_date, page) do
    objects =
      Cheque.deposit_index_query(
        terms,
        d_date,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end

  defp url_from_search(socket) do
    qry = %{
      "search[terms]" => socket.assigns.search.terms,
      "search[d_date]" => socket.assigns.search.d_date
    }

    "/companies/#{socket.assigns.current_company.id}/Deposit?#{URI.encode_query(qry)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[35rem] grow shrink">
              <.input
                label={gettext("Terms")}
                id="search_terms"
                name="search[terms]"
                value={@search.terms}
                placeholder={gettext("bank, deposit no or particulars...")}
              />
            </div>
            <div class="w-[13rem] grow shrink">
              <.input
                label={gettext("Date From")}
                name="search[d_date]"
                type="date"
                id="search_d_date"
                value={@search.d_date}
              />
            </div>

            <.button class="mt-5 h-10 w-30 grow-0 shrink-0">
              <%= gettext("Query") %>
            </.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/Deposit/new"}
          class="blue button"
          id="new_invoice"
        >
          <%= gettext("New Deposit") %>
        </.link>
      </div>

      <div class="text-center font-medium flex flex-row tracking-tighter bg-green-200 border-green-400 border-y-2">
        <div class="w-[15%] px-2 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[15%] px-2 py-1">
          <%= gettext("Deposit No") %>
        </div>
        <div class="w-[28%] px-2 py-1 ">
          <%= gettext("Deposit Bank") %>
        </div>
        <div class="w-[27%] px-2 py-1 ">
          <%= gettext("Particulars") %>
        </div>
        <div class="w-[15%] px-2 py-1">
          <%= gettext("Amount") %>
        </div>
      </div>

      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update="stream"
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={FullCircleWeb.ChequeLive.DepositIndexComponent}
            id={obj_id}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
