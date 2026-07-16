defmodule FullCircleWeb.StatutoryCalcLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.StatutoryConfig
  alias FullCircleWeb.StatutoryCalcLive.IndexComponent

  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_statutory_config,
         socket.assigns.current_company
       ) do
      {:ok,
       socket
       |> assign(page_title: gettext("Statutory Calc Listing"))
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

    url =
      "/companies/#{socket.assigns.current_company.id}/statutory_calcs?#{URI.encode_query(qry)}"

    {:noreply, push_patch(socket, to: url)}
  end

  defp assign_objects(socket, terms) do
    com_id = socket.assigns.current_company.id

    objects =
      StatutoryConfig.list_versions(:calc, com_id)
      |> Enum.filter(fn c ->
        terms == "" or
          String.contains?(String.downcase(c.code), String.downcase(terms)) or
          String.contains?(String.downcase(c.name), String.downcase(terms))
      end)

    assign(socket, objects: objects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.search_form search_val={@search.terms} placeholder={gettext("Code or name...")} live />
      <div class="text-center mb-2 flex justify-center gap-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/statutory_calcs/new"}
          class="blue button"
          id="new_object"
        >
          {gettext("New Version")}
        </.link>
        <a
          href={~p"/companies/#{@current_company.id}/statutory_bundle/export"}
          class="blue button"
        >
          {gettext("Export bundle")}
        </a>
        <.link
          navigate={~p"/companies/#{@current_company.id}/statutory_bundle/import"}
          class="blue button"
        >
          {gettext("Import bundle")}
        </.link>
      </div>
      <div class="text-center">
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2">
          {gettext("Calc Versions")}
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
