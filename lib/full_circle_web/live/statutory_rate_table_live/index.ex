defmodule FullCircleWeb.StatutoryRateTableLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.StatutoryConfig
  alias FullCircleWeb.StatutoryRateTableLive.IndexComponent

  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_statutory_config,
         socket.assigns.current_company
       ) do
      {:ok,
       socket
       |> assign(page_title: gettext("Statutory Rate Table Listing"))
       |> assign(search: %{terms: ""})
       |> assign_objects("")}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    terms = get_in(params, ["search", "terms"]) || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms})
     |> assign_objects(terms)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    qry = %{"search[terms]" => terms}
    url = "/companies/#{socket.assigns.current_company.id}/statutory_rate_tables?#{URI.encode_query(qry)}"
    {:noreply, push_patch(socket, to: url)}
  end

  defp assign_objects(socket, terms) do
    com_id = socket.assigns.current_company.id

    objects =
      StatutoryConfig.list_versions(:table, com_id)
      |> Enum.filter(fn t ->
        terms == "" or
          String.contains?(String.downcase(t.code), String.downcase(terms)) or
          String.contains?(to_string(t.effective_from), terms)
      end)

    assign(socket, objects: objects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.search_form search_val={@search.terms} placeholder={gettext("Code or effective date...")} live />
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/statutory_rate_tables/new"}
          class="blue button"
          id="new_object"
        >
          {gettext("New Version")}
        </.link>
      </div>
      <div class="text-center">
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2">
          {gettext("Rate Table Versions")}
        </div>
      </div>
      <div :if={Enum.count(@objects) > 0} id="objects_list">
        <%= for obj <- @objects do %>
          <.live_component
            current_company={@current_company}
            current_role={@current_role}
            module={IndexComponent}
            id={obj.id}
            obj={obj}
            ex_class=""
          />
        <% end %>
      </div>
    </div>
    """
  end
end