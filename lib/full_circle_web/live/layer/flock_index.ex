defmodule FullCircleWeb.LayerLive.FlockIndex do
  use FullCircleWeb, :live_view

  alias FullCircleWeb.LayerLive.FlockIndexComponent
  alias FullCircle.Layer.Flock
  alias FullCircle.StdInterface

  @per_page 50

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[15.5rem] grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_terms"
                name="search[terms]"
                type="search"
                value={@search.terms}
                placeholder="flock no, breed..."
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>DOB From</label>
              <.input
                name="search[dob]"
                type="date"
                value={@search.dob}
                id="search_dob"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/flocks/new"}
          class="blue button"
          id="new_flock"
        >
          <%= gettext("New Flock") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("DOB") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Flock No") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Breed") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Quantity") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Houses") %>
        </div>
        <div class="w-[25%] border-b border-t border-amber-400 py-1">
          <%= gettext("Note") %>
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
            module={FlockIndexComponent}
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

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Flock Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    dob = params["dob"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, dob: dob})
     |> assign(can_print: false)
     |> filter_objects(terms, true, dob, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.dob,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "dob" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[dob]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/flocks?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  import Ecto.Query, warn: false


  defp filter_objects(socket, terms, reset, "", page) do
    from(obj in Flock,
    join:
      com in subquery(
        FullCircle.Sys.user_company(
          socket.assigns.current_company,
          socket.assigns.current_user
        )
      ),
    on: com.id == obj.company_id
  ) |> filter(socket, terms, reset, page)
  end

  defp filter_objects(socket, terms, reset, dob, page) do
    from(obj in Flock,
    join:
      com in subquery(
        FullCircle.Sys.user_company(
          socket.assigns.current_company,
          socket.assigns.current_user
        )
      ),
    on: com.id == obj.company_id,
    where: obj.dob >= ^dob
  ) |> filter(socket, terms, reset, page)
  end

  defp filter(qry, socket, terms, reset, page) do
    objects =
      StdInterface.filter(
        qry,
        [:flock_no, :breed, :note],
        terms,
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
end
