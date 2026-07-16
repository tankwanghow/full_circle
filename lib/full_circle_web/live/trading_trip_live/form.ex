defmodule FullCircleWeb.TradingTripLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.{Trip, TripLoad, TripDrop}
  alias FullCircle.Authorization
  alias FullCircle.Product
  alias FullCircle.Accounting

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
          Trip.changeset(%Trip{}, %{
            "company_id" => company.id,
            "status" => "draft",
            "date" => Date.utc_today() |> Date.to_iso8601(),
            "transport_mode" => "company_own",
            "loads" => [%{}],
            "drops" => [%{}]
          })

        {:ok, assign_form(socket, cs, :new, nil)}

      true ->
        trip = Trading.get_trip!(params["id"], company, user)

        cs =
          Trip.changeset(trip, %{
            "good_name" => trip.good && trip.good.name,
            "transport_agent_name" => trip.transport_agent && trip.transport_agent.name
          })

        {:ok, assign_form(socket, cs, :edit, trip)}
    end
  end

  defp assign_form(socket, cs, live_action, trip) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    title =
      case live_action do
        :new -> gettext("New Trip")
        :edit -> gettext("Edit Trip")
      end

    socket
    |> assign(page_title: title)
    |> assign(live_action: live_action)
    |> assign(trip: trip)
    |> assign(form: to_form(cs))
    |> assign(locations: Trading.list_locations(company, user, active_only: true))
    |> assign(supplies: Trading.list_supply_positions(company, user, status: "open"))
    |> assign(sales: Trading.list_open_sales(company, user))
    |> assign(warnings: if(trip, do: Trading.trip_warnings(trip), else: []))
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["trip", "good_name"], "trip" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "good_name",
        "good_id",
        &Product.get_good_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["trip", "transport_agent_name"], "trip" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "transport_agent_name",
        "transport_agent_id",
        &Accounting.get_contact_by_name/3
      )

    validate(params, socket)
  end

  def handle_event("validate", %{"trip" => params}, socket) do
    validate(params, socket)
  end

  def handle_event("add_load", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:loads, %TripLoad{})
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("add_drop", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:drops, %TripDrop{})
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("delete_load", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :loads)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("delete_drop", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :drops)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"trip" => params}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    params = ensure_ids(params, company, user)

    result =
      case socket.assigns.live_action do
        :new -> Trading.create_trip(params, company, user)
        :edit -> Trading.update_trip(socket.assigns.trip, params, company, user)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Trip saved successfully."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/trips")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      {:error, :trip_locked} ->
        {:noreply, put_flash(socket, :error, gettext("Completed or cancelled trips cannot be edited."))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("complete", _, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    trip = socket.assigns.trip

    case Trading.complete_trip(trip, company, user) do
      {:ok, _trip, warnings} ->
        msg =
          if warnings == [] do
            gettext("Trip completed.")
          else
            gettext("Trip completed with warnings: ") <> Enum.join(warnings, "; ")
          end

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/trips")}

      {:error, :missing_actuals} ->
        {:noreply, put_flash(socket, :error, gettext("All loads and drops need actual MT."))}

      {:error, :good_mismatch} ->
        {:noreply, put_flash(socket, :error, gettext("Load/drop product does not match trip good."))}

      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, gettext("Could not complete trip (%{reason})", reason: reason))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not complete trip."))}
    end
  end

  def handle_event("cancel_trip", _, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case Trading.cancel_trip(socket.assigns.trip, company, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Trip cancelled."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/trips")}

      {:error, :has_invoices} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot cancel: a drop is already invoiced."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not cancel trip."))}
    end
  end

  defp validate(params, socket) do
    params = Map.put(params, "company_id", socket.assigns.current_company.id)

    cs =
      case socket.assigns.live_action do
        :new -> Trip.changeset(%Trip{}, params)
        :edit -> Trip.changeset(socket.assigns.trip, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  defp ensure_ids(params, company, user) do
    params =
      case Product.get_good_by_name(params["good_name"] || "", company, user) do
        %{id: id} -> Map.put(params, "good_id", id)
        _ -> params
      end

    case Accounting.get_contact_by_name(params["transport_agent_name"] || "", company, user) do
      %{id: id} -> Map.put(params, "transport_agent_id", id)
      _ -> params
    end
  end

  defp location_options(locations) do
    Enum.map(locations, &{&1.name, &1.id})
  end

  defp supply_options(supplies) do
    [{gettext("(none)"), ""} | Enum.map(supplies, &{&1.title, &1.id})]
  end

  defp sales_options(sales) do
    [{gettext("(none)"), ""} | Enum.map(sales, &{&1.title, &1.id})]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <div :if={@warnings != []} class="mb-3 p-2 bg-amber-100 border border-amber-400 text-sm rounded">
        <p class="font-semibold">{gettext("Warnings")}</p>
        <ul class="list-disc ml-5">
          <li :for={w <- @warnings}>{w}</li>
        </ul>
      </div>

      <.form
        for={@form}
        id="trip-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="p-4 border rounded space-y-3"
      >
        <div class="flex gap-2 flex-wrap">
          <.input field={@form[:date]} type="date" label={gettext("Date")} />
          <.input field={@form[:reference_no]} label={gettext("Reference")} />
          <div class="w-[25%]">
            <.input
              field={@form[:transport_mode]}
              type="select"
              label={gettext("Transport mode")}
              options={Enum.map(Trip.transport_modes(), &{&1, &1})}
            />
          </div>
          <div class="w-[15%]">
            <.input
              field={@form[:status]}
              type="select"
              label={gettext("Status")}
              options={Enum.map(Trip.statuses(), &{&1, &1})}
              disabled={@live_action == :edit && @trip && @trip.status in ["completed", "cancelled"]}
            />
          </div>
        </div>

        <div class="flex gap-2">
          <div class="w-[40%]">
            <.input
              field={@form[:good_name]}
              label={gettext("Good")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
            />
            <.input type="hidden" field={@form[:good_id]} />
          </div>
          <div class="w-[40%]">
            <.input
              field={@form[:transport_agent_name]}
              label={gettext("Transport agent")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
            <.input type="hidden" field={@form[:transport_agent_id]} />
          </div>
        </div>

        <.input field={@form[:notes]} type="textarea" label={gettext("Notes")} />

        <div class="border-t pt-2">
          <p class="font-semibold text-lg mb-1">{gettext("Loads")}</p>
          <.inputs_for :let={load} field={@form[:loads]}>
            <div class={[
              "grid grid-cols-12 gap-1 mb-2 items-end",
              if(load[:delete].value in [true, "true"], do: "hidden")
            ]}>
              <.input type="hidden" field={load[:delete]} />
              <div class="col-span-3">
                <.input
                  field={load[:location_id]}
                  type="select"
                  label={gettext("Location")}
                  options={location_options(@locations)}
                  prompt={gettext("Select…")}
                />
              </div>
              <div class="col-span-3">
                <.input
                  field={load[:supply_position_id]}
                  type="select"
                  label={gettext("Supply")}
                  options={supply_options(@supplies)}
                />
              </div>
              <div class="col-span-2">
                <.input field={load[:planned_mt]} type="number" step="any" label={gettext("Planned MT")} />
              </div>
              <div class="col-span-2">
                <.input field={load[:actual_mt]} type="number" step="any" label={gettext("Actual MT")} />
              </div>
              <div class="col-span-1">
                <.input field={load[:location_note]} label={gettext("Note")} />
              </div>
              <div class="col-span-1 pb-1">
                <button type="button" phx-click="delete_load" phx-value-index={load.index} class="red button text-xs">
                  {gettext("Del")}
                </button>
              </div>
            </div>
          </.inputs_for>
          <button type="button" phx-click="add_load" class="blue button text-sm">
            {gettext("Add load")}
          </button>
        </div>

        <div class="border-t pt-2">
          <p class="font-semibold text-lg mb-1">{gettext("Drops")}</p>
          <.inputs_for :let={drop} field={@form[:drops]}>
            <div class={[
              "grid grid-cols-12 gap-1 mb-2 items-end",
              if(drop[:delete].value in [true, "true"], do: "hidden")
            ]}>
              <.input type="hidden" field={drop[:delete]} />
              <div class="col-span-2">
                <.input
                  field={drop[:location_id]}
                  type="select"
                  label={gettext("Location")}
                  options={location_options(@locations)}
                  prompt={gettext("Select…")}
                />
              </div>
              <div class="col-span-2">
                <.input
                  field={drop[:sales_position_id]}
                  type="select"
                  label={gettext("Sales")}
                  options={sales_options(@sales)}
                />
              </div>
              <div class="col-span-2">
                <.input
                  field={drop[:supply_position_id]}
                  type="select"
                  label={gettext("Supply")}
                  options={supply_options(@supplies)}
                />
              </div>
              <div class="col-span-2">
                <.input field={drop[:planned_mt]} type="number" step="any" label={gettext("Planned MT")} />
              </div>
              <div class="col-span-2">
                <.input field={drop[:actual_mt]} type="number" step="any" label={gettext("Actual MT")} />
              </div>
              <div class="col-span-1">
                <.input field={drop[:variance_note]} label={gettext("Variance")} />
              </div>
              <div class="col-span-1 pb-1">
                <button type="button" phx-click="delete_drop" phx-value-index={drop.index} class="red button text-xs">
                  {gettext("Del")}
                </button>
              </div>
            </div>
          </.inputs_for>
          <button type="button" phx-click="add_drop" class="blue button text-sm">
            {gettext("Add drop")}
          </button>
        </div>

        <div class="text-center mt-4 gap-1 flex flex-wrap justify-center">
          <.button :if={is_nil(@trip) or @trip.status not in ["completed", "cancelled"]}>
            {gettext("Save")}
          </.button>
          <button
            :if={@live_action == :edit && @trip && @trip.status in ["draft", "planned"]}
            type="button"
            phx-click="complete"
            class="orange button"
            data-confirm={gettext("Complete this trip? Actuals will update balances.")}
          >
            {gettext("Complete trip")}
          </button>
          <button
            :if={@live_action == :edit && @trip && @trip.status != "cancelled"}
            type="button"
            phx-click="cancel_trip"
            class="red button"
            data-confirm={gettext("Cancel this trip?")}
          >
            {gettext("Cancel trip")}
          </button>
          <.link navigate={~p"/companies/#{@current_company.id}/trading/trips"} class="gray button">
            {gettext("Back")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
