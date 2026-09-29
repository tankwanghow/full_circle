defmodule FullCircleWeb.NoteLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :view_notes,
         socket.assigns.current_company
       ) do
      {:ok, assign(socket, page_title: gettext("Notes"))}
    else
      {:ok,
       socket
       |> put_flash(:warn, gettext("Not Authorise."))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    terms = get_in(params, ["search", "terms"]) || ""
    filters = Map.take(params["filters"] || %{}, ~w(subject_type mine from to))

    {:noreply,
     socket
     |> assign(search: %{terms: terms}, filters: filters)
     |> load(1, true)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket, terms, socket.assigns.filters))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket, socket.assigns.search.terms, filters))}
  end

  def handle_event("next-page", _, socket) do
    {:noreply, load(socket, socket.assigns.page + 1, false)}
  end

  # Not `url/3`: Phoenix.VerifiedRoutes imports a url macro of that arity.
  defp index_path(socket, terms, filters) do
    q =
      %{"search[terms]" => terms}
      |> Map.merge(Map.new(filters, fn {k, v} -> {"filters[#{k}]", v} end))
      |> URI.encode_query()

    "/companies/#{socket.assigns.current_company.id}/notes?#{q}"
  end

  defp load(socket, page, reset) do
    notes =
      Notes.search(
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.search.terms,
        socket.assigns.filters,
        page: page,
        per_page: @per_page
      )
      |> FullCircle.Repo.preload(:attachments)

    socket
    |> assign(page: page, end_of_timeline?: length(notes) < @per_page)
    |> stream(:notes, notes, reset: reset)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12 max-md:w-11/12">
      <p class="w-full text-center text-3xl font-medium">{@page_title}</p>
      <.search_form
        live
        search_val={@search.terms}
        placeholder={gettext("Words in the title or body...")}
      />
      <form
        id="filter-form"
        phx-change="filter"
        class="mb-2 flex flex-wrap items-end justify-center gap-2 text-sm"
      >
        <label>
          {gettext("About")}
          <select name="filters[subject_type]" class="rounded border-gray-300 text-sm">
            <option value="">{gettext("Anything")}</option>
            <option :for={t <- Linkable.types()} value={t} selected={@filters["subject_type"] == t}>
              {type_label(t)}
            </option>
          </select>
        </label>
        <label>
          <input type="hidden" name="filters[mine]" value="false" />
          <input
            type="checkbox"
            name="filters[mine]"
            value="true"
            checked={@filters["mine"] == "true"}
          />
          {gettext("Written by me")}
        </label>
        <label>{gettext("From")}
        <input
          type="date"
          name="filters[from]"
          value={@filters["from"]}
          class="rounded border-gray-300 text-sm"
        /></label>
        <label>{gettext("To")}
        <input
          type="date"
          name="filters[to]"
          value={@filters["to"]}
          class="rounded border-gray-300 text-sm"
        /></label>
      </form>
      <div class="mb-2 text-center">
        <.link
          :if={FullCircle.Authorization.can?(@current_user, :create_note, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/notes/new"}
          class="blue button"
        >
          {gettext("New Note")}
        </.link>
      </div>
      <div id="notes_list" phx-update="stream" phx-viewport-bottom={!@end_of_timeline? && "next-page"}>
        <div :for={{dom_id, note} <- @streams.notes} id={dom_id}>
          <.note_card note={note} current_company={@current_company} />
          <div :if={note.subject_type} class="-mt-1 mb-2 pl-2 text-xs text-gray-500">
            {gettext("About")} {type_label(note.subject_type)}
          </div>
        </div>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
