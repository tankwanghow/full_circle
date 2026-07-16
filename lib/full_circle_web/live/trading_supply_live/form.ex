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
            "status" => "open"
          })

        {:ok,
         socket
         |> assign(page_title: gettext("New Supply Position"))
         |> assign(live_action: :new)
         |> assign(form: to_form(cs))
         |> assign(good_unit: nil)}

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
         |> assign(form: to_form(cs))
         |> assign(good_unit: s.good && s.good.unit)}
    end
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["supply_position", "supplier_name"], "supply_position" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "supplier_name",
        "supplier_id",
        &Accounting.get_contact_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["supply_position", "good_name"], "supply_position" => params},
        socket
      ) do
    {params, socket, good} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "good_name",
        "good_id",
        &Product.get_good_by_name/3
      )

    socket = assign(socket, good_unit: good && Map.get(good, :unit))
    validate(params, socket)
  end

  def handle_event("validate", %{"supply_position" => params}, socket) do
    validate(params, socket)
  end

  def handle_event("save", %{"supply_position" => params}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    params = ensure_ids(params, company, user)

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
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("hold", _params, socket) do
    set_supply_status(
      socket,
      &Trading.hold_supply_position/3,
      gettext("Supply marked hold (collection held by supplier).")
    )
  end

  def handle_event("collect", _params, socket) do
    set_supply_status(
      socket,
      &Trading.collect_supply_position/3,
      gettext("Supply marked collect (supplier allows collection).")
    )
  end

  def handle_event("close", _params, socket) do
    set_supply_status(
      socket,
      &Trading.close_supply_position/3,
      gettext("Supply position closed.")
    )
  end

  defp set_supply_status(socket, fun, ok_msg) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case fun.(socket.assigns.supply, company, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, ok_msg)
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/supply_positions")}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not update supply status."))}
    end
  end

  defp validate(params, socket) do
    params = Map.put(params, "company_id", socket.assigns.current_company.id)

    cs =
      case socket.assigns.live_action do
        :new -> SupplyPosition.changeset(%SupplyPosition{}, params)
        :edit -> SupplyPosition.changeset(socket.assigns.supply, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  defp ensure_ids(params, company, user) do
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

  defp status_options do
    Enum.map(SupplyPosition.statuses(), fn s ->
      {gettext("%{label}", label: SupplyPosition.status_label(s)), s}
    end)
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
        <.input
          field={@form[:title]}
          label={gettext("Name / ref")}
          placeholder={gettext("e.g. JON DOE May maize, PO-8841, Ah Huat pollard")}
          required
        />
        <div class="flex gap-2">
          <div class="w-[60%]">
            <.input
              field={@form[:supplier_name]}
              label={gettext("Supplier")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
            <.input type="hidden" field={@form[:supplier_id]} />
          </div>
          <.input
            field={@form[:available_from]}
            type="date"
            label={gettext("Est. available to load")}
          />
          <div class="w-[28%]">
            <.input
              field={@form[:status]}
              type="select"
              label={gettext("Status")}
              options={status_options()}
            />
          </div>
        </div>
        <div class="flex gap-2">
          <div class="w-[50%]">
            <.input
              field={@form[:good_name]}
              label={gettext("Good")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
            />
            <.input type="hidden" field={@form[:good_id]} />
          </div>
          <.input field={@form[:quantity]} type="number" step="any" label={gettext("Quantity")} />
          <div class="w-[10%]">
            <label class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200">
              {gettext("Unit")}
            </label>
            <div
              id="good-unit-display"
              class="flex h-8.5 rounded items-center border border-zinc-300 bg-zinc-100 px-3 text-sm font-medium dark:border-zinc-600 dark:bg-zinc-800"
            >
              {if @good_unit, do: @good_unit, else: gettext("(from Good)")}
            </div>
          </div>
          <.input
            field={@form[:unit_price]}
            type="number"
            step="any"
            label={gettext("Unit price")}
          />
        </div>
        <.input field={@form[:notes]} type="textarea" label={gettext("Notes")} />
        <div class="text-center mt-4 gap-1 flex flex-wrap justify-center">
          <.button>{gettext("Save")}</.button>
          <button
            :if={@live_action == :edit && @supply.status in ["open", "collect"]}
            type="button"
            phx-click="hold"
            class="blue button"
          >
            {gettext("Mark hold")}
          </button>
          <button
            :if={@live_action == :edit && @supply.status in ["open", "hold"]}
            type="button"
            phx-click="collect"
            class="teal button"
          >
            {gettext("Mark collect")}
          </button>
          <button
            :if={@live_action == :edit && @supply.status != "close"}
            type="button"
            phx-click="close"
            class="orange button"
            data-confirm={gettext("Close this supply position? Stock ended.")}
          >
            {gettext("Close")}
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
