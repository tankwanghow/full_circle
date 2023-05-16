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
      <span
        class="text-xl font-bold px-2 py-1 rounded-full border hover:bg-blue-400 cursor-pointer bg-blue-100 border-blue-500"
        phx-value-object-id={@obj.id}
        phx-click={:edit_object}
      >
        <%= @obj.name %> (<%= @obj.unit %>)
      </span>
      <p
        :if={@obj.packagings |> Enum.filter(fn x -> !is_nil(x) end) |> Enum.count() > 0}
        class="text-sm font-light"
      >
        <span class="font-normal"><%= gettext("Packagings") %></span>
        :- <%= @obj.packagings
        |> Enum.map(fn x -> x.name end)
        |> Enum.join(", ") %>
      </p>
      <p>
        <%= @obj.sales_account_name %> &#11049; <%= @obj.sales_tax_code_name %> &#8226; <%= @obj.purchase_account_name %> &#11049; <%= @obj.purchase_tax_code_name %>
      </p>
      <p><%= @obj.descriptions %></p>
      <.live_component
        module={FullCircleWeb.LogLive.Component}
        id={"log_#{@obj.id}"}
        show_log={false}
        entity="goods"
        entity_id={@obj.id}
      />
      <span class="ml-1 text-xs font-light"><%= to_fc_time_format(@obj.updated_at) %></span>
      <span
        phx-click={:copy_object}
        class="text-xs hover:bg-orange-400 bg-orange-200 py-1 px-2 rounded-full border-orange-400 border"
        phx-value-object-id={@obj.id}
      >
        <%= gettext("Copy") %>
      </span>
    </div>
    """
  end
end
