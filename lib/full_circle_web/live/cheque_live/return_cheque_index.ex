defmodule FullCircleWeb.ChequeLive.ReturnChequeIndex do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.{Cheque}
  alias FullCircleWeb.NoteLive.NotesIndex

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Return Cheques")
      |> NotesIndex.init("ReturnCheque", FullCircleWeb.ChequeLive.ReturnChequeIndexComponent,
        key: :return_id
      )

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
     |> push_navigate(to: url_from_search(socket))}
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
    |> NotesIndex.count(objects, reset)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end

  defp url_from_search(socket) do
    qry = %{
      "search[terms]" => socket.assigns.search.terms,
      "search[r_date]" => socket.assigns.search.r_date
    }

    "/companies/#{socket.assigns.current_company.id}/ReturnCheque?#{URI.encode_query(qry)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Terms")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              value={@search.terms}
              placeholder={gettext("bank, deposit no or particulars...")}
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("Date From")}</.filter_label>
            <.input
              name="search[r_date]"
              type="date"
              id="search_r_date"
              value={@search.r_date}
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              navigate={~p"/companies/#{@current_company.id}/ReturnCheque/new"}
              class="blue button"
              id="new_return_cheque"
            >
              + {gettext("New Return Cheque")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table gap="gap-0">
        <:head>
          <div class="w-[13%] shrink-0 px-1">{gettext("Date")}</div>
          <div class="w-[12%] shrink-0 px-1">{gettext("Return No")}</div>
          <div class="w-[30%] shrink-0 px-1">{gettext("Customer")}</div>
          <div class="w-[30%] shrink-0 px-1">{gettext("Particulars")}</div>
          <div class="w-[15%] shrink-0 px-1 text-right">{gettext("Amount")}</div>
        </:head>
        <div
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={FullCircleWeb.ChequeLive.ReturnChequeIndexComponent}
              note_count={Map.get(@note_counts, obj.return_id, 0)}
              task_count={Map.get(@task_counts, obj.return_id, 0)}
              id={obj_id}
              obj={obj}
              company={@current_company}
              ex_class=""
            />
          <% end %>
        </div>
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
      <NotesIndex.modal
        notes_for={@notes_for}
        notes_type={@notes_type}
        current_company={@current_company}
        current_user={@current_user}
      />
    </div>
    """
  end
end
