defmodule FullCircleWeb.TradingSupplyLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.SupplyPosition
  alias FullCircle.Authorization
  alias FullCircle.Accounting
  alias FullCircle.Product

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    cond do
      not Authorization.can?(user, :manage_trading, company) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))
         |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}

      socket.assigns.live_action == :new ->
        cs =
          SupplyPosition.changeset(%SupplyPosition{}, %{
            "company_id" => company.id,
            "status" => "open",
            "unit" => "MT"
          })

        {:ok,
         socket
         |> assign(page_title: gettext("New Supply Position"))
         |> assign(live_action: :new)
         |> assign(form: to_form(cs))}

      true ->
        s = Trading.get_supply_position!(params["id"], company, user)

        cs =
          SupplyPosition.changeset(s, %{
            "supplier_name" => s.supplier && s.supplier.name,
            "good_name" => s.good && s.good.name
          })

        {:ok,
         socket
         |> assign(page_title: gettext("Edit Supply Position"))
         |> assign(live_action: :edit)
         |> assign(supply: s)
         |> assign(form: to_form(cs))}
    end
  end

  @impl true
  def handle_event("validate", %{"supply_position" => params}, socket) do
    params = resolve_names(params, socket)
    params = Map.put(params, "company_id", socket.assigns.current_company.id)

    cs =
      case socket.assigns.live_action do
        :new -> SupplyPosition.changeset(%SupplyPosition{}, params)
        :edit -> SupplyPosition.changeset(socket.assigns.supply, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"supply_position" => params}, socket) do
    params = resolve_names(params, socket)
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :new -> Trading.create_supply_position(params, company, user)
        :edit -> Trading.update_supply_position(socket.assigns.supply, params, company, user)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Supply position saved successfully."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/supply_positions")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      :not_authorise ->
        {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("close", _params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case Trading.close_supply_position(socket.assigns.supply, company, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Supply position closed."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/supply_positions")}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not close supply position."))}
    end
  end

  defp resolve_names(params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    params =
      case Accounting.get_contact_by_name(params["supplier_name"] || "", company, user) do
        %{id: id} -> Map.put(params, "supplier_id", id)
        _ -> params
      end

    case Product.get_good_by_name(params["good_name"] || "", company, user) do
      %{id: id} -> Map.put(params, "good_id", id)
      _ -> params
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="supply-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="p-4 border rounded space-y-2"
      >
        <.input field={@form[:title]} label={gettext("Title")} />
        <.input field={@form[:reference_no]} label={gettext("Reference no")} />
        <.input field={@form[:vessel_name]} label={gettext("Vessel name")} />
        <.input field={@form[:period]} label={gettext("Period")} />
        <div class="grid grid-cols-2 gap-2">
          <.input field={@form[:supplier_name]} label={gettext("Supplier")} phx-debounce="300" />
          <.input field={@form[:good_name]} label={gettext("Good")} phx-debounce="300" />
        </div>
        <div class="grid grid-cols-3 gap-2">
          <.input field={@form[:quantity]} type="number" step="any" label={gettext("Quantity")} />
          <.input field={@form[:unit]} label={gettext("Unit")} />
          <.input field={@form[:unit_price]} type="number" step="any" label={gettext("Unit price")} />
        </div>
        <.input
          field={@form[:status]}
          type="select"
          label={gettext("Status")}
          options={Enum.map(SupplyPosition.statuses(), &{&1, &1})}
        />
        <.input field={@form[:notes]} type="textarea" label={gettext("Notes")} />
        <div class="text-center mt-4 gap-1 flex flex-wrap justify-center">
          <.button>{gettext("Save")}</.button>
          <button
            :if={@live_action == :edit && @supply.status == "open"}
            type="button"
            phx-click="close"
            class="orange button"
            data-confirm={gettext("Close this supply position?")}
          >
            {gettext("Close position")}
          </button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/trading/supply_positions"}
            class="gray button"
          >
            {gettext("Back")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
