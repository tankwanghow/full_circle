defmodule FullCircleWeb.TaxCodeLive.IndexComponent do
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
      class={"#{@ex_class} text-center bg-gray-200 border-gray-500 hover:bg-gray-300border-b p-1"}
    >
      <.link
        :if={!FullCircle.Accounting.is_default_tax_code?(@obj)}
        class="hover:font-bold text-blue-600"
        navigate={~p"/companies/#{@current_company.id}/tax_codes/#{@obj.id}/edit"}
      >
        <%= @obj.code %> (<%= @obj.tax_type %> &#11049; <%= @obj.rate
        |> Decimal.mult(100)
        |> Number.Percentage.number_to_percentage() %> &#11049; <%= @obj.account_name %>)
      </.link>
      <span :if={FullCircle.Accounting.is_default_tax_code?(@obj)} class="font-bold text-rose-600">
        <%= @obj.code %> (<%= @obj.tax_type %> &#11049; <%= @obj.rate
        |> Decimal.mult(100)
        |> Number.Percentage.number_to_percentage() %> &#11049; <%= @obj.account_name %>)
      </span>
      <p class="tracking-tighter font-light text-amber-800 leading-5"><%= @obj.descriptions %></p>
    </div>
    """
  end
end
