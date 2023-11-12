defmodule FullCircleWeb.TaxCodeLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting
  alias FullCircle.StdInterface
  alias FullCircleWeb.TaxCodeLive.IndexComponent

  @per_page 30

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Code, Tax Type, Account Name and Descriptions...")}
      />
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/tax_codes/new"}
          class="blue button"
          id="new_object"
        >
          <%= gettext("New TaxCode") %>
        </.link>
      </div>
      <div class="text-center">
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2">
          <%= gettext("TaxCode Information") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update={@update_action}
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            current_company={@current_company}
            module={IndexComponent}
            id={"#{obj_id}"}
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
      |> assign(update_action: "replace")
      |> assign(page_title: gettext("TaxCode Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms})
     |> assign(update_action: "replace")
     |> filter_objects(terms, true, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> assign(update_action: "append")
     |> filter_objects(socket.assigns.search.terms, false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    qry = %{
      "search[terms]" => terms
    }

    url = "/companies/#{socket.assigns.current_company.id}/tax_codes?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, reset, page) do
    query = Accounting.tax_code_query(socket.assigns.current_company, socket.assigns.current_user)

    objects =
      StdInterface.filter(query, [:code, :tax_type, :account_name, :descriptions], terms,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
