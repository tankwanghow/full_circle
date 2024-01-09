defmodule FullCircleWeb.ChequeLive.ReturnChequeIndex do
  use FullCircleWeb, :live_view

  alias FullCircle.{Cheque}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Return Cheques")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""
    r_date = params["r_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, r_date: r_date})
     |> filter_objects(terms, true, r_date, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.r_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "terms" => terms,
            "r_date" => r_date
          }
        },
        socket
      ) do
    socket =
      socket
      |> assign(search: %{terms: terms, r_date: r_date})

    {:noreply,
     socket
     |> push_patch(to: url_from_search(socket))}
  end

  defp filter_objects(socket, terms, reset, r_date, page) do
    objects =
      Cheque.return_cheque_index_query(
        terms,
        r_date,
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
      "search[r_date]" => socket.assigns.search.r_date
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
                name="search[r_date]"
                type="date"
                id="search_r_date"
                value={@search.r_date}
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
          navigate={~p"/companies/#{@current_company.id}/ReturnCheque/new"}
          class="blue button"
          id="new_return_cheque"
        >
          <%= gettext("New Return Cheque") %>
        </.link>
      </div>

      <div class="text-center font-medium flex flex-row tracking-tighter bg-green-200 border-green-400 border-y-2">
        <div class="w-[13%] px-2 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[12%] px-2 py-1">
          <%= gettext("Return No") %>
        </div>
        <div class="w-[30%] px-2 py-1 ">
          <%= gettext("Customer") %>
        </div>
        <div class="w-[30%] px-2 py-1 ">
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
            module={FullCircleWeb.ChequeLive.ReturnChequeIndexComponent}
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
