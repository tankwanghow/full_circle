defmodule FullCircleWeb.ReportLive.TaggedBill do
  use FullCircleWeb, :live_view

  alias FullCircle.{Reporting}
  # alias FullCircleWeb.ReportLive.StatementComponent

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Tagged Bill")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    tags = params["tags"] || ""

    f_date =
      params["f_date"] ||
        Timex.shift(Timex.today(), months: -1) |> Timex.format!("%Y-%m-%d", :strftime)

    t_date = params["t_date"] || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
     |> assign(search: %{tags: tags, f_date: f_date, t_date: t_date})
     |> query(tags, f_date, t_date)
     |> assign(can_print: false)
     |> assign(selected: [])}
  end

  @impl true
  def handle_event("changed", _, socket) do
    {:noreply, socket |> assign(objects: [])}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "tags" => tags,
            "f_date" => f_date,
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[tags]" => tags,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/tagged_bill?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_patch(to: url)}
  end

  defp query(socket, tags, f_date, t_date) do
    objects =
      if tags == "" or f_date == "" or t_date == "" do
        []
      else
        Reporting.tagged_bill(tags, f_date, t_date, socket.assigns.current_company)
      end

    socket
    |> assign(objects: objects)
    |> assign(objects_count: Enum.count(objects))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto mb-8">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" phx-change="changed" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-7">
              <.input
                label={gettext("Tags")}
                name="search[tags]"
                id="search_tags"
                value={@search.tags}
                phx-hook="tributeTagText"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/billingtags?tag="}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("To")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-1 mt-5">
              <.button>
                <%= gettext("Query") %>
              </.button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
