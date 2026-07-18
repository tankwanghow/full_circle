defmodule FullCircleWeb.TradingDeskLive.SupplyFormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Trading
  alias FullCircle.Trading.SupplyPosition
  alias FullCircle.Accounting
  alias FullCircle.Product

  @impl true
  def update(assigns, socket) do
    company = assigns.company
    user = assigns.user
    action = assigns.action

    socket =
      socket
      |> assign(assigns)
      |> assign(current_company: company, current_user: user)

    socket =
      case action do
        :new ->
          cs =
            SupplyPosition.changeset(%SupplyPosition{}, %{
              "company_id" => company.id,
              "status" => "open",
              "title" => "...new..."
            })

          socket
          |> assign(page_title: gettext("New Supply Position"))
          |> assign(live_action: :new)
          |> assign(supply: nil)
          |> assign(form: to_form(cs))
          |> assign(good_unit: nil)

        :edit ->
          s = Trading.get_supply_position!(assigns.supply_id, company, user)

          cs =
            SupplyPosition.changeset(s, %{
              "supplier_name" => s.supplier && s.supplier.name,
              "good_name" => s.good && s.good.name
            })

          socket
          |> assign(page_title: gettext("Edit Supply Position"))
          |> assign(live_action: :edit)
          |> assign(supply: s)
          |> assign(form: to_form(cs))
          |> assign(good_unit: s.good && s.good.unit)
      end

    {:ok, socket}
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
        send(self(), {:desk_modal_saved, :supply})
        {:noreply, socket}

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
        send(self(), {:desk_modal_saved, :supply, ok_msg})
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not update supply status."))}
    end
  end

  defp validate(params, socket) do
    params =
      params
      |> Map.put("company_id", socket.assigns.current_company.id)
      |> put_system_title(socket)

    cs =
      case socket.assigns.live_action do
        :new -> SupplyPosition.changeset(%SupplyPosition{}, params)
        :edit -> SupplyPosition.changeset(socket.assigns.supply, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  defp put_system_title(params, %{assigns: %{live_action: :new}}),
    do: Map.put(params, "title", "...new...")

  defp put_system_title(params, %{assigns: %{supply: %{title: title}}}),
    do: Map.put(params, "title", title)

  defp put_system_title(params, _), do: params

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
    <div>
      <p class="w-full text-2xl text-center font-medium mb-2">{@page_title}</p>
      <.form
        for={@form}
        id="desk-supply-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        autocomplete="off"
        class="space-y-2"
      >
        <div class="flex gap-2">
          <div class="w-[40%]">
            <.input
              field={@form[:title]}
              label={gettext("Supply no")}
              readonly
              tabindex="-1"
            />
          </div>
          <div class="w-[60%]">
            <.input
              field={@form[:status]}
              type="select"
              label={gettext("Status")}
              options={status_options()}
            />
          </div>
        </div>
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
            <div class="flex h-8.5 rounded items-center border border-zinc-300 bg-zinc-100 px-3 text-sm font-medium dark:border-zinc-600 dark:bg-zinc-800">
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
            phx-target={@myself}
            class="blue button"
          >
            {gettext("Mark hold")}
          </button>
          <button
            :if={@live_action == :edit && @supply.status in ["open", "hold"]}
            type="button"
            phx-click="collect"
            phx-target={@myself}
            class="teal button"
          >
            {gettext("Mark collect")}
          </button>
          <button
            :if={@live_action == :edit && @supply.status != "closed"}
            type="button"
            phx-click="close"
            phx-target={@myself}
            class="orange button"
            data-confirm={gettext("Close this supply position? Stock ended.")}
          >
            {gettext("Close")}
          </button>
          <button type="button" phx-click="close_modal" class="gray button">
            {gettext("Cancel")}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
