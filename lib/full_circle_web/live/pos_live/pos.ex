defmodule FullCircleWeb.PosLive do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex mx-auto w-[80%] h-[45rem] border border-black gap-3">
      <div class="w-2/3 h-[90%] bg-gray-500 p-10 rounded-xl">
        <.input
          label={gettext("Search for products")}
          type="search"
          id="search_goods"
          name="search_goods"
          phx-hook="tributeAutoComplete"
          phx-blur="find_good"
          class="rounded h-8 p-1 border mb-1"
          autocomplete="off"
          url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
          value=""
        />
      </div>
      <div class="w-1/3 h-[90%] bg-gray-500 rounded-xl">
      </div>
    </div>
    """
  end
end
