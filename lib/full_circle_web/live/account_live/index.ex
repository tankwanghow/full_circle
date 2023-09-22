defmodule FullCircleWeb.AccountLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.Account
  alias FullCircle.StdInterface
  alias FullCircleWeb.AccountLive.IndexComponent

  @per_page 30

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-4/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Name, AccountType and Descriptions...")}
      />
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/accounts/new"}
          class="blue button"
          id="new_account"
        >
          <%= gettext("New Account") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Account Information") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update={@update}
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            current_company={@current_company}
            current_role={@current_role}
            module={IndexComponent}
            id={obj_id}
            obj={obj}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Accounts Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms})
     |> filter_objects(terms, "replace", 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(socket.assigns.search.terms, "stream", socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    qry = %{
      "search[terms]" => terms
    }

    url = "/companies/#{socket.assigns.current_company.id}/accounts?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, update, page) do
    objects =
      StdInterface.filter(
        Account,
        [:name, :account_type, :descriptions],
        terms,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> assign(update: update)
    |> stream(:objects, objects, reset: obj_count == 0)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
