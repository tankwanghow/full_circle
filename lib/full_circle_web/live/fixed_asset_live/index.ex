defmodule FullCircleWeb.FixedAssetLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting
  alias FullCircle.StdInterface
  alias FullCircleWeb.FixedAssetLive.IndexComponent

  @per_page 30

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Name, Asset Account, Depreciation Account or Descriptions...")}
      />
      <div class="text-center mb-2">
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets/new"} class="blue button">
          <%= gettext("New Fixed Asset") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/fixed_assets/calalldepre"}
          class="blue button"
          id="calculate_depre"
        >
          <%= gettext("Calculate Depreciations") %>
        </.link>
      </div>
      <div class="text-center">
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2">
          <%= gettext("Fixed Asset Information") %>
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
            module={IndexComponent}
            id={"#{obj_id}"}
            obj={obj}
            current_company={@current_company}
            ex_class=""
            terms={@search.terms}
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

      |> assign(page_title: gettext("Fixed Asset Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms})

     |> filter_objects(terms, true, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket

     |> filter_objects(socket.assigns.search.terms, false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    qry = %{
      "search[terms]" => terms
    }

    url = "/companies/#{socket.assigns.current_company.id}/fixed_assets?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, reset, page) do
    query =
      Accounting.fixed_asset_query(socket.assigns.current_company, socket.assigns.current_user)

    objects =
      StdInterface.filter(
        query,
        [:name, :asset_ac_name, :depre_ac_name, :descriptions],
        terms,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
