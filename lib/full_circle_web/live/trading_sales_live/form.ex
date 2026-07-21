defmodule FullCircleWeb.TradingSalesLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.SalesPosition
  alias FullCircle.Authorization
  alias FullCircle.Accounting
  alias FullCircle.Product
  import FullCircleWeb.TradingComponents

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
          SalesPosition.changeset(%SalesPosition{}, %{
            "company_id" => company.id,
            "status" => "draft",
            "title" => "...new..."
          })

        {:ok,
         socket
         |> assign(page_title: gettext("New Sales Position"))
         |> assign(live_action: :new)
         |> assign(form: to_form(cs))
         |> assign(good_unit: nil)
         |> assign(drop_history: [])}

      true ->
        s = Trading.get_sales_position!(params["id"], company, user)
        drops = Trading.list_sales_line_history(s.id, company, user)

        cs =
          SalesPosition.changeset(s, %{
            "customer_name" => s.customer && s.customer.name,
            "good_name" => s.good && s.good.name,
            "preferred_supply_title" => s.preferred_supply && s.preferred_supply.title
          })

        {:ok,
         socket
         |> assign(page_title: gettext("Edit Sales Position"))
         |> assign(live_action: :edit)
         |> assign(sales: s)
         |> assign(form: to_form(cs))
         |> assign(good_unit: s.good && s.good.unit)
         |> assign(drop_history: drops)}
    end
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["sales_position", "customer_name"], "sales_position" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "customer_name",
        "customer_id",
        &Accounting.get_contact_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["sales_position", "good_name"], "sales_position" => params},
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

  def handle_event(
        "validate",
        %{"_target" => ["sales_position", "preferred_supply_title"], "sales_position" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "preferred_supply_title",
        "preferred_supply_id",
        &Trading.get_open_supply_position_by_title/3
      )

    validate(params, socket)
  end

  def handle_event("validate", %{"sales_position" => params}, socket) do
    validate(params, socket)
  end

  def handle_event("save", %{"sales_position" => params}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    params = ensure_ids(params, company, user)

    result =
      case socket.assigns.live_action do
        :new -> Trading.create_sales_position(params, company, user)
        :edit -> Trading.update_sales_position(socket.assigns.sales, params, company, user)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Sales position saved successfully."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/sales_positions")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("open", _params, socket) do
    set_sales_status(
      socket,
      &Trading.open_sales_position/3,
      gettext("Sales position opened."),
      :open_sales
    )
  end

  def handle_event("hold", _params, socket) do
    set_sales_status(
      socket,
      &Trading.hold_sales_position/3,
      gettext("Sales position on hold."),
      :open_sales
    )
  end

  def handle_event("fulfill", %{"fulfilled_note" => note}, socket) do
    do_fulfill(socket, note)
  end

  def handle_event("fulfill", _params, socket) do
    note =
      case socket.assigns.form do
        %{params: %{"fulfilled_note" => n}} -> n
        %{source: %{changes: %{fulfilled_note: n}}} -> n
        _ -> socket.assigns.sales.fulfilled_note
      end

    do_fulfill(socket, note)
  end

  def handle_event("cancel_sales", _params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case Trading.cancel_sales_position(socket.assigns.sales, company, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Sales position cancelled."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/sales_positions")}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not cancel sales position."))}
    end
  end

  defp set_sales_status(socket, fun, ok_msg, :open_sales) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case fun.(socket.assigns.sales, company, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, ok_msg)
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/open_sales")}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not update sales status."))}
    end
  end

  defp do_fulfill(socket, note) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case Trading.fulfill_sales_position(
           socket.assigns.sales,
           %{"fulfilled_note" => note},
           company,
           user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Sales position fulfilled."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/open_sales")}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not fulfill sales position."))}
    end
  end

  defp validate(params, socket) do
    params =
      params
      |> Map.put("company_id", socket.assigns.current_company.id)
      |> put_system_title(socket)

    cs =
      case socket.assigns.live_action do
        :new -> SalesPosition.changeset(%SalesPosition{}, params)
        :edit -> SalesPosition.changeset(socket.assigns.sales, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  defp put_system_title(params, %{assigns: %{live_action: :new}}),
    do: Map.put(params, "title", "...new...")

  defp put_system_title(params, %{assigns: %{sales: %{title: title}}}),
    do: Map.put(params, "title", title)

  defp put_system_title(params, _), do: params

  defp status_options do
    Enum.map(SalesPosition.statuses(), fn s ->
      {gettext("%{label}", label: SalesPosition.status_label(s)), s}
    end)
  end

  defp ensure_ids(params, company, user) do
    params =
      case Accounting.get_contact_by_name(params["customer_name"] || "", company, user) do
        %{id: id} -> Map.put(params, "customer_id", id)
        _ -> params
      end

    params =
      case Product.get_good_by_name(params["good_name"] || "", company, user) do
        %{id: id} -> Map.put(params, "good_id", id)
        _ -> params
      end

    case Trading.get_open_supply_position_by_title(
           params["preferred_supply_title"] || "",
           company,
           user
         ) do
      %{id: id} -> Map.put(params, "preferred_supply_id", id)
      _ -> Map.put(params, "preferred_supply_id", nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12 max-w-5xl">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="sales-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="p-4 border rounded space-y-2"
      >
        <div class="flex gap-2">
          <div class="w-[30%]">
            <.input
              field={@form[:title]}
              label={gettext("Sales no")}
              readonly
              tabindex="-1"
            />
          </div>
          <div class="w-[40%]">
            <.input
              field={@form[:customer_name]}
              label={gettext("Customer")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
            <.input type="hidden" field={@form[:customer_id]} />
          </div>
          <.input
            field={@form[:available_from]}
            type="date"
            label={gettext("Est. needed by")}
          />
          <div class="w-[20%]">
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
        <.input
          field={@form[:preferred_supply_title]}
          label={gettext("Preferred supply (soft hold)")}
          placeholder={gettext("Supply no — does not reduce remaining")}
          phx-hook="tributeAutoComplete"
          url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=opensupply&name="}
        />
        <.input type="hidden" field={@form[:preferred_supply_id]} />
        <.input field={@form[:notes]} type="textarea" label={gettext("Notes")} />
        <.input
          :if={@live_action == :edit}
          field={@form[:fulfilled_note]}
          type="textarea"
          label={gettext("Fulfilled note")}
        />
        <div class="mt-4 flex flex-wrap items-center justify-between gap-3">
          <%!-- Form actions (left) --%>
          <div class="flex flex-wrap gap-1">
            <.button>{gettext("Save")}</.button>
            <.print_button
              :if={@live_action == :edit && @sales}
              doc_type="trading/sales_positions"
              doc_id={@sales.id}
              company={@current_company}
              class="blue button"
            />
            <.link
              navigate={~p"/companies/#{@current_company.id}/trading/sales_positions"}
              class="gray button"
            >
              {gettext("Back")}
            </.link>
          </div>
          <%!-- Status transitions (right) --%>
          <div
            :if={
              @live_action == :edit &&
                @sales.status in ["draft", "open", "hold"]
            }
            class="flex flex-wrap items-center gap-1 sm:border-l sm:border-zinc-200 sm:pl-3"
          >
            <span class="text-xs font-medium text-zinc-500 mr-1">
              {gettext("Update status")}
            </span>
            <button
              :if={@sales.status in ["draft", "hold"]}
              type="button"
              phx-click="open"
              class="blue button"
            >
              {gettext("Open")}
            </button>
            <button
              :if={@sales.status in ["draft", "open"]}
              type="button"
              phx-click="hold"
              class="teal button"
            >
              {gettext("Mark hold")}
            </button>
            <button
              :if={@sales.status in ["draft", "open", "hold"]}
              type="button"
              phx-click="fulfill"
              class="orange button"
              data-confirm={gettext("Mark this sales position fulfilled even if undelivered remains?")}
            >
              {gettext("Mark fulfilled")}
            </button>
            <button
              :if={@sales.status in ["draft", "open", "hold"]}
              type="button"
              phx-click="cancel_sales"
              class="red button"
              data-confirm={gettext("Cancel this sales position?")}
            >
              {gettext("Cancel sales")}
            </button>
          </div>
        </div>
      </.form>

      <div :if={@live_action == :edit}>
        <.movement_history
          title={gettext("Loads & drops")}
          rows={@drop_history}
          company_id={@current_company.id}
          empty_text={gettext("No drops to this sales yet.")}
          base_qty={@sales && @sales.quantity}
          unit={@good_unit}
          remaining_from={:drop}
          print_href={
            @sales &&
              ~p"/companies/#{@current_company.id}/trading/sales_positions/#{@sales.id}/history/print"
          }
        />
      </div>
    </div>
    """
  end
end
