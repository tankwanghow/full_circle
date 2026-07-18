defmodule FullCircleWeb.TradingTripLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.{Trip, TripLoad, TripDrop}
  alias FullCircle.Authorization
  alias FullCircle.Accounting
  import Ecto.Query, warn: false
  import FullCircleWeb.TradingTripLive.DetailLines

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
            "reference_no" => "...new...",
            "loads" => [%{}],
            "drops" => [%{}]
          })

        {:ok, assign_form(socket, cs, :new, nil)}

      true ->
        trip = Trading.get_trip!(params["id"], company, user)

        cs =
          Trip.changeset(trip, %{
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
        :edit -> gettext("Edit Trip") <> " " <> (trip.reference_no || "")
      end

    socket
    |> assign(page_title: title)
    |> assign(live_action: live_action)
    |> assign(trip: trip)
    |> assign(form: to_form(cs))
    |> assign(locations: Trading.list_locations(company, user, active_only: true))
    |> assign(
      goods:
        FullCircle.Repo.all(
          from(g in FullCircle.Product.Good,
            where: g.company_id == ^company.id,
            order_by: g.name
          )
        )
    )
    |> assign(
      supplies:
        Trading.list_supply_positions(company, user,
          statuses: FullCircle.Trading.SupplyPosition.loadable_statuses()
        )
    )
    |> assign(sales: Trading.list_open_sales(company, user))
    |> assign(warnings: if(trip, do: Trading.trip_warnings(trip), else: []))
  end

  @impl true
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
        {:noreply,
         put_flash(socket, :error, gettext("Completed or cancelled trips cannot be edited."))}

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
        {:noreply,
         put_flash(socket, :error, gettext("Load/drop product does not match the line good."))}

      {:error, reason} when is_atom(reason) ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not complete trip (%{reason})", reason: reason))}

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
    params =
      params
      |> Map.put("company_id", socket.assigns.current_company.id)
      |> put_system_reference_no(socket)

    cs =
      case socket.assigns.live_action do
        :new -> Trip.changeset(%Trip{}, params)
        :edit -> Trip.changeset(socket.assigns.trip, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  defp put_system_reference_no(params, %{assigns: %{live_action: :new}}),
    do: Map.put(params, "reference_no", "...new...")

  defp put_system_reference_no(params, %{assigns: %{trip: %{reference_no: ref}}}),
    do: Map.put(params, "reference_no", ref)

  defp put_system_reference_no(params, _), do: params

  defp ensure_ids(params, company, user) do
    params =
      case Accounting.get_contact_by_name(params["transport_agent_name"] || "", company, user) do
        %{id: id} -> Map.put(params, "transport_agent_id", id)
        _ -> params
      end

    supplies =
      Trading.list_supply_positions(company, user,
        statuses: FullCircle.Trading.SupplyPosition.loadable_statuses()
      )
    sales = Trading.list_open_sales(company, user)
    fill_line_goods(params, supplies, sales)
  end

  defp fill_line_goods(params, supplies, sales) do
    supply_map = Map.new(supplies, &{&1.id, &1})
    sales_map = Map.new(sales, &{&1.id, &1})

    loads =
      Map.new(params["loads"] || %{}, fn {k, load} ->
        load = Map.new(load, fn {kk, vv} -> {to_string(kk), vv} end)
        sid = load["supply_position_id"]
        load =
          if sid not in [nil, ""] and Map.has_key?(supply_map, sid) do
            s = supply_map[sid]
            Map.put(load, "good_id", s.good_id)
          else
            load
          end
        {k, load}
      end)

    drops =
      Map.new(params["drops"] || %{}, fn {k, drop} ->
        drop = Map.new(drop, fn {kk, vv} -> {to_string(kk), vv} end)
        sales_id = drop["sales_position_id"]
        drop =
          if sales_id not in [nil, ""] and Map.has_key?(sales_map, sales_id) do
            s = sales_map[sales_id]
            Map.put(drop, "good_id", s.good_id)
          else
            drop
          end
        {k, drop}
      end)

    params |> Map.put("loads", loads) |> Map.put("drops", drops)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-950/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.error_box changeset={@form.source} />

      <div
        :if={@warnings != []}
        class="mb-3 p-2 bg-amber-100 border border-amber-400 text-sm rounded"
      >
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
      >
        <div class="flex flex-row flex-nowrap gap-1">
        <div class="w-[14%] grow shrink">
            <.input
              field={@form[:reference_no]}
              label={gettext("Trip no")}
              readonly
              tabindex="-1"
            />
          </div>
          <div class="w-[14%] grow shrink">
            <.input field={@form[:date]} type="date" label={gettext("Date")} />
          </div>
          <div class="w-[18%] grow shrink">
            <.input
              field={@form[:transport_mode]}
              type="select"
              label={gettext("Transport mode")}
              options={Enum.map(Trip.transport_modes(), &{&1, &1})}
            />
          </div>
          <div class="w-[14%] grow shrink">
            <.input field={@form[:vehicle_number]} label={gettext("Vehicle no")} />
          </div>
          <div class="w-[28%] grow shrink">
            <.input
              field={@form[:transport_agent_name]}
              label={gettext("Transport agent")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
            <.input type="hidden" field={@form[:transport_agent_id]} />
          </div>
        </div>

        <div class="flex flex-row flex-nowrap mt-1">
          <div class="w-full">
            <.input field={@form[:notes]} label={gettext("Notes")} />
          </div>
          <div class="w-[12%] grow shrink">
            <.input
              field={@form[:status]}
              type="select"
              label={gettext("Status")}
              options={Enum.map(Trip.statuses(), &{&1, &1})}
              disabled={@live_action == :edit && @trip && @trip.status in ["completed", "cancelled"]}
            />
          </div>
        </div>

        <.loads_section form={@form} goods={@goods} locations={@locations} supplies={@supplies} />
        <.drops_section
          form={@form}
          goods={@goods}
          locations={@locations}
          supplies={@supplies}
          sales={@sales}
        />

        <div class="flex flex-row justify-center gap-x-1 mt-3 flex-wrap">
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
