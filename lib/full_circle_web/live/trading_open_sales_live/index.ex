defmodule FullCircleWeb.TradingOpenSalesLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.Balances
  alias FullCircle.Authorization

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_trading, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Open Sales"))
       |> load_rows()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("fulfill", %{"id" => id}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :manage_trading, company) do
      sales = Trading.get_sales_position!(id, company, user)

      case Trading.fulfill_sales_position(sales, %{}, company, user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Sales position fulfilled."))
           |> load_rows()}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Could not fulfill sales position."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp load_rows(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    rows =
      company
      |> Trading.list_open_sales(user)
      |> Enum.map(fn s ->
        delivered = Balances.sales_delivered(s)
        undelivered = Balances.sales_undelivered(s)

        %{
          sales: s,
          ordered: s.quantity,
          delivered: delivered,
          undelivered: undelivered
        }
      end)

    assign(socket, :rows, rows)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-3 gap-1 flex flex-wrap justify-center">
        <.link
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/sales_positions/new"}
          class="blue button"
        >
          {gettext("New Sales")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/sales_positions"}
          class="teal button"
        >
          {gettext("All Sales")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/position_board"}
          class="teal button"
        >
          {gettext("Position Board")}
        </.link>
      </div>

      <div class="overflow-x-auto">
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 grid grid-cols-11 gap-1 text-xs md:text-sm min-w-[1080px]">
          <div>{gettext("Sales")}</div>
          <div>{gettext("Needed by")}</div>
          <div>{gettext("Customer")}</div>
          <div>{gettext("Good")}</div>
          <div class="text-center">{gettext("Unit")}</div>
          <div class="text-right">{gettext("Ordered")}</div>
          <div class="text-right">{gettext("Delivered")}</div>
          <div class="text-right">{gettext("Undelivered")}</div>
          <div>{gettext("Preferred supply")}</div>
          <div>{gettext("Status")}</div>
          <div></div>
        </div>
        <div id="open_sales" class="min-w-[1080px]">
          <div
            :for={row <- @rows}
            id={"open-sales-#{row.sales.id}"}
            class="grid grid-cols-11 gap-1 border-b p-2 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
          >
            <div>
              <.link
                navigate={
                  ~p"/companies/#{@current_company.id}/trading/sales_positions/#{row.sales.id}/edit"
                }
                class="text-blue-600"
              >
                {row.sales.title || "—"}
              </.link>
            </div>
            <div>{row.sales.available_from}</div>
            <div>{row.sales.customer && row.sales.customer.name}</div>
            <div>{row.sales.good && row.sales.good.name}</div>
            <div class="text-center font-medium">{row.sales.good && row.sales.good.unit}</div>
            <div class="text-right">{row.ordered}</div>
            <div class="text-right">{row.delivered}</div>
            <div class={[
              "text-right font-semibold",
              undelivered_class(row.undelivered)
            ]}>
              {row.undelivered}
            </div>
            <div>
              {row.sales.preferred_supply && (row.sales.preferred_supply.title || "—")}
            </div>
            <div>{row.sales.status}</div>
            <div class="text-center">
              <button
                :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
                type="button"
                id={"fulfill-#{row.sales.id}"}
                phx-click="fulfill"
                phx-value-id={row.sales.id}
                class="orange button text-xs"
                data-confirm={gettext("Mark fulfilled even if undelivered remains?")}
              >
                {gettext("Mark fulfilled")}
              </button>
            </div>
          </div>
        </div>
      </div>
      <p :if={@rows == []} class="text-center p-4 text-gray-500">
        {gettext("No open sales commitments.")}
      </p>
    </div>
    """
  end

  defp undelivered_class(nil), do: ""

  defp undelivered_class(qty) do
    if Decimal.compare(qty, Decimal.new(0)) == :gt do
      "text-amber-700"
    else
      ""
    end
  end
end

