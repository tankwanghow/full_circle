defmodule FullCircleWeb.GoodLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={"#{@ex_class} text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded p-2"}
    >
      <.link
        class="text-blue-600 hover:font-bold"
        navigate={~p"/companies/#{@current_company}/goods/#{@obj.id}/edit"}
      >
        <%= @obj.name %> (<%= @obj.unit %>)
      </.link>
      &#11049;
      <span
        :if={@obj.packagings |> Enum.filter(fn x -> !is_nil(x) end) |> Enum.count() > 0}
        class="text-sm font-light"
      >
        <span class="font-normal"><%= gettext("Packagings") %></span>
        :- <%= @obj.packagings
        |> Enum.map(fn x -> x.name end)
        |> Enum.join(", ") %>
      </span>
      <span>
        <%= @obj.sales_account_name %> &#11049; <%= @obj.sales_tax_code_name %> &#8226; <%= @obj.purchase_account_name %> &#11049; <%= @obj.purchase_tax_code_name %>
      </span>
      <.link
        navigate={~p"/companies/#{@current_company}/goods/#{@obj.id}/copy"}
        class="text-xs hover:bg-orange-400 bg-orange-200 py-1 px-2 rounded-full border-orange-400 border"
      >
        <%= gettext("Copy") %>
      </.link>
    </div>
    """
  end
end
