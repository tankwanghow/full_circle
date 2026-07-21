defmodule FullCircleWeb.TradingDeskLive.TripFormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Trading
  alias FullCircle.Trading.{Trip, TripLoad, TripDrop}
  alias FullCircle.Accounting
  alias FullCircle.Product
  import FullCircleWeb.TradingTripLive.DetailLines

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
          prefill = Map.get(assigns, :prefill) || %{}

          base = %{
            "company_id" => company.id,
            "status" => "draft",
            "date" => Date.utc_today() |> Date.to_iso8601(),
            "transport_mode" => "company_own",
            "reference_no" => "...new...",
            "loads" => [%{}],
            "drops" => [%{}]
          }

          # Prefill from desk selection; cast_assoc expects index maps ("%{"0" => ...}")
          attrs =
            base
            |> Map.merge(stringify_map(prefill))
            |> normalize_assoc_params("loads")
            |> normalize_assoc_params("drops")
            |> backfill_all_line_labels(company, user)

          cs = Trip.changeset(%Trip{}, attrs)
          assign_form(socket, cs, :new, nil)

        :edit ->
          trip = Trading.get_trip!(assigns.trip_id, company, user)
          trip = put_line_display_names(trip)

          cs =
            Trip.changeset(trip, %{
              "transport_agent_name" => trip.transport_agent && trip.transport_agent.name
            })

          assign_form(socket, cs, :edit, trip)
      end

    {:ok, socket}
  end

  defp put_line_display_names(%Trip{} = trip) do
    loads =
      Enum.map(List.wrap(trip.loads), fn l ->
        %{
          l
          | good_name: l.good && l.good.name,
            location_name: location_label(l.location),
            supply_title: supply_label(l.supply_position),
            party_contact_id: l.supply_position && l.supply_position.supplier_id
        }
      end)

    drops =
      Enum.map(List.wrap(trip.drops), fn d ->
        %{
          d
          | good_name: d.good && d.good.name,
            location_name: location_label(d.location),
            sales_title: sales_label(d.sales_position),
            supply_title: supply_label(d.supply_position),
            party_contact_id: d.sales_position && d.sales_position.customer_id
        }
      end)

    %{trip | loads: loads, drops: drops}
  end

  defp location_label(%{name: name, kind: kind}) when is_binary(name),
    do: if(kind && kind != "", do: "#{name} (#{kind})", else: name)

  defp location_label(_), do: nil

  defp supply_label(%{title: title, supplier: %{name: sn}}) when is_binary(title),
    do: "#{title} · #{sn}"

  defp supply_label(%{title: title}) when is_binary(title), do: title
  defp supply_label(_), do: nil

  defp sales_label(%{title: title, customer: %{name: cn}}) when is_binary(title),
    do: "#{title} · #{cn}"

  defp sales_label(%{title: title}) when is_binary(title), do: title
  defp sales_label(_), do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_val(v)}
      {k, v} -> {to_string(k), stringify_val(v)}
    end)
  end

  defp stringify_map(_), do: %{}

  defp stringify_val(list) when is_list(list), do: Enum.map(list, &stringify_val/1)
  defp stringify_val(map) when is_map(map), do: stringify_map(map)
  defp stringify_val(other), do: other

  # Ecto cast_assoc for forms uses string indexes; accept list or map prefill.
  defp normalize_assoc_params(attrs, key) do
    case Map.get(attrs, key) do
      list when is_list(list) and list != [] ->
        indexed =
          list
          |> Enum.with_index()
          |> Map.new(fn {item, i} -> {Integer.to_string(i), stringify_val(item)} end)

        Map.put(attrs, key, indexed)

      map when is_map(map) and map_size(map) > 0 ->
        Map.put(attrs, key, stringify_map(map))

      _ ->
        Map.put(attrs, key, %{"0" => %{}})
    end
  end

  defp assign_form(socket, cs, live_action, trip) do
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

  def handle_event(
        "validate",
        %{"_target" => ["trip", "loads", id, field], "trip" => params},
        socket
      )
      when field in ["good_name", "location_name", "supply_title"] do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    detail = resolve_load_typeahead(params["loads"][id], field, company, user)
    params = FullCircleWeb.Helpers.merge_detail(params, "loads", id, detail)
    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["trip", "drops", id, field], "trip" => params},
        socket
      )
      when field in ["good_name", "location_name", "sales_title", "supply_title"] do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    detail = resolve_drop_typeahead(params["drops"][id], field, company, user)
    params = FullCircleWeb.Helpers.merge_detail(params, "drops", id, detail)
    validate(params, socket)
  end

  def handle_event("validate", %{"trip" => params}, socket) do
    validate(params, socket)
  end

  def handle_event("add_load", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:loads, %TripLoad{seq: next_seq(socket, :loads)})
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("add_drop", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:drops, %TripDrop{seq: next_seq(socket, :drops)})
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("delete_load", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :loads)
      |> FullCircleWeb.Helpers.renumber_lines(:loads)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("delete_drop", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :drops)
      |> FullCircleWeb.Helpers.renumber_lines(:drops)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("move_load", %{"index" => index, "dir" => dir}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.move_line(index, :loads, dir)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("move_drop", %{"index" => index, "dir" => dir}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.move_line(index, :drops, dir)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("reverse_loads", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.reverse_lines(:loads)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("reverse_drops", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.reverse_lines(:drops)
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
        send(self(), {:desk_modal_saved, :trip})
        {:noreply, socket}

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

        send(self(), {:desk_modal_saved, :trip, msg})
        {:noreply, socket}

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
        send(self(), {:desk_modal_saved, :trip, gettext("Trip cancelled.")})
        {:noreply, socket}

      {:error, :has_invoices} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot cancel: a drop is already invoiced."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not cancel trip."))}
    end
  end

  defp next_seq(socket, assoc) do
    lines = Ecto.Changeset.get_assoc(socket.assigns.form.source, assoc) || []

    lines
    |> Enum.reject(fn line ->
      case line do
        %Ecto.Changeset{} = cs -> Ecto.Changeset.get_field(cs, :delete) in [true, "true"]
        %{delete: d} -> d in [true, "true"]
        _ -> false
      end
    end)
    |> length()
    |> Kernel.+(1)
  end

  defp validate(params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    params =
      params
      |> Map.put("company_id", company.id)
      |> put_system_reference_no(socket)
      |> clear_agent_if_not_agent_mode()
      |> resolve_all_line_typeaheads(company, user)

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

  # Agent only applies when transport_mode is "agent"; clear otherwise so hidden fields don't stick.
  defp clear_agent_if_not_agent_mode(%{"transport_mode" => mode} = params)
       when mode != "agent" do
    params
    |> Map.put("transport_agent_id", nil)
    |> Map.put("transport_agent_name", nil)
  end

  defp clear_agent_if_not_agent_mode(params), do: params

  defp ensure_ids(params, company, user) do
    params = clear_agent_if_not_agent_mode(params)

    params =
      if params["transport_mode"] == "agent" do
        case Accounting.get_contact_by_name(params["transport_agent_name"] || "", company, user) do
          %{id: id} -> Map.put(params, "transport_agent_id", id)
          _ -> params
        end
      else
        params
      end

    resolve_all_line_typeaheads(params, company, user)
  end

  defp resolve_load_typeahead(detail, field, company, user) do
    detail = stringify_keys_one(detail)

    case field do
      # Supply drives good. When supply set, re-sync good from supply (good is readonly in UI).
      "good_name" ->
        if supply_present?(detail) do
          resolve_load_typeahead(detail, "supply_title", company, user)
        else
          resolve_named(
            detail,
            "good_name",
            "good_id",
            fn name -> Product.get_good_by_name(name, company, user) end,
            fn
              %{id: id, value: name} -> %{"good_id" => id, "good_name" => name}
              _ -> %{}
            end,
            fn id ->
              case FullCircle.Repo.get(FullCircle.Product.Good, id) do
                %{name: name} -> %{"good_name" => name}
                _ -> %{}
              end
            end
          )
        end

      "location_name" ->
        contact_id = detail["party_contact_id"]

        resolve_named(
          detail,
          "location_name",
          "location_id",
          fn name ->
            Trading.get_location_by_name(name, company, user, contact_id: contact_id)
          end,
          fn
            %{} = loc -> %{"location_id" => loc.id, "location_name" => location_label(loc)}
            _ -> %{}
          end,
          fn id ->
            try do
              loc = Trading.get_location!(id, company, user)
              %{"location_name" => location_label(loc)}
            rescue
              _ -> %{}
            end
          end
        )

      "supply_title" ->
        # Supply first: set good + supplier party; auto location if sole site
        detail =
          resolve_named(
            detail,
            "supply_title",
            "supply_position_id",
            fn name -> Trading.get_open_supply_position_by_title(name, company, user) end,
            fn
              %{} = s ->
                %{
                  "supply_position_id" => s.id,
                  "supply_title" => supply_label(s),
                  "good_id" => s.good_id,
                  "good_name" => s.good && s.good.name,
                  "party_contact_id" => s.supplier_id
                }

              _ ->
                %{}
            end,
            fn id ->
              try do
                s = Trading.get_supply_position!(id, company, user)

                %{
                  "supply_title" => supply_label(s),
                  "good_id" => s.good_id,
                  "good_name" => s.good && s.good.name,
                  "party_contact_id" => s.supplier_id
                }
              rescue
                _ -> %{}
              end
            end
          )

        if present_id?(detail["supply_position_id"]) do
          apply_party_location(detail, company, user)
        else
          Map.put(detail, "party_contact_id", nil)
        end
    end
  end

  defp supply_present?(detail) do
    sid = detail["supply_position_id"]
    title = detail["supply_title"] |> to_string() |> String.trim()
    present_id?(sid) or title != ""
  end

  defp resolve_drop_typeahead(detail, field, company, user) do
    detail = stringify_keys_one(detail)

    case field do
      # Sales drives good. When sales set, ignore free good edits and re-sync from sales.
      "good_name" ->
        if sales_present?(detail) do
          detail
          |> resolve_drop_typeahead("sales_title", company, user)
          |> drop_mismatched_supply(company, user)
        else
          detail
          |> resolve_named(
            "good_name",
            "good_id",
            fn name -> Product.get_good_by_name(name, company, user) end,
            fn
              %{id: id, value: name} -> %{"good_id" => id, "good_name" => name}
              _ -> %{}
            end,
            fn id ->
              case FullCircle.Repo.get(FullCircle.Product.Good, id) do
                %{name: name} -> %{"good_name" => name}
                _ -> %{}
              end
            end
          )
          |> drop_mismatched_supply(company, user)
        end

      "location_name" ->
        resolve_load_typeahead(detail, "location_name", company, user)

      "sales_title" ->
        # Sales first: set good + customer party; auto location if sole site
        detail =
          resolve_named(
            detail,
            "sales_title",
            "sales_position_id",
            fn name -> Trading.get_open_sales_position_by_title(name, company, user) end,
            fn
              %{} = s ->
                %{
                  "sales_position_id" => s.id,
                  "sales_title" => sales_label(s),
                  "good_id" => s.good_id,
                  "good_name" => s.good && s.good.name,
                  "party_contact_id" => s.customer_id
                }

              _ ->
                %{}
            end,
            fn id ->
              try do
                s = Trading.get_sales_position!(id, company, user)

                %{
                  "sales_title" => sales_label(s),
                  "good_id" => s.good_id,
                  "good_name" => s.good && s.good.name,
                  "party_contact_id" => s.customer_id
                }
              rescue
                _ -> %{}
              end
            end
          )

        detail =
          if present_id?(detail["sales_position_id"]) do
            apply_party_location(detail, company, user)
          else
            Map.put(detail, "party_contact_id", nil)
          end

        drop_mismatched_supply(detail, company, user)

      "supply_title" ->
        line_good = detail["good_id"]

        resolve_named(
          detail,
          "supply_title",
          "supply_position_id",
          fn name ->
            case Trading.get_open_supply_position_by_title(name, company, user) do
              %{} = s ->
                if matching_good?(line_good, s.good_id), do: s, else: nil

              _ ->
                nil
            end
          end,
          fn
            %{} = s ->
              %{"supply_position_id" => s.id, "supply_title" => supply_label(s)}

            _ ->
              %{}
          end,
          fn id ->
            try do
              s = Trading.get_supply_position!(id, company, user)

              if matching_good?(line_good, s.good_id) or line_good in [nil, ""] do
                %{"supply_title" => supply_label(s)}
              else
                %{}
              end
            rescue
              _ -> %{}
            end
          end
        )
    end
  end

  defp sales_present?(detail) do
    sid = detail["sales_position_id"]
    title = detail["sales_title"] |> to_string() |> String.trim()
    present_id?(sid) or title != ""
  end

  # Filter/auto location for supplier or customer contact (1 contact → many sites).
  defp apply_party_location(detail, company, user) do
    contact_id = detail["party_contact_id"]

    cond do
      contact_id in [nil, ""] ->
        detail

      true ->
        locs = Trading.list_locations_for_contact(contact_id, company, user)
        lid = detail["location_id"]

        case locs do
          [one] ->
            detail
            |> Map.put("location_id", one.id)
            |> Map.put("location_name", location_label(one))

          many when is_list(many) and many != [] ->
            kept? =
              lid not in [nil, ""] and
                Enum.any?(many, &(to_string(&1.id) == to_string(lid)))

            if kept? do
              detail
            else
              detail
              |> Map.put("location_id", nil)
              |> Map.put("location_name", nil)
            end

          _ ->
            detail
        end
    end
  end

  defp matching_good?(line_good, _pos_good) when line_good in [nil, ""], do: true

  defp matching_good?(line_good, pos_good),
    do: to_string(line_good) == to_string(pos_good)

  # If line good is set and supply is for another good, clear supply.
  defp drop_mismatched_supply(detail, company, user) do
    good_id = detail["good_id"]
    sid = detail["supply_position_id"]

    cond do
      good_id in [nil, ""] or sid in [nil, ""] ->
        detail

      true ->
        try do
          s = Trading.get_supply_position!(sid, company, user)

          if matching_good?(good_id, s.good_id) do
            detail
          else
            detail
            |> Map.put("supply_position_id", nil)
            |> Map.put("supply_title", nil)
          end
        rescue
          _ ->
            detail
            |> Map.put("supply_position_id", nil)
            |> Map.put("supply_title", nil)
        end
    end
  end

  # Resolve typeahead text → id. If text blank but id present, keep id and fill label.
  # Only clear id when text is non-empty but does not match a record.
  defp resolve_named(detail, name_key, id_key, lookup_by_name, from_record, from_id) do
    name = detail[name_key] |> to_string() |> String.trim()
    id = detail[id_key]

    cond do
      name != "" ->
        case lookup_by_name.(name) do
          nil ->
            detail |> Map.put(id_key, nil)

          rec ->
            Map.merge(detail, from_record.(rec))
        end

      present_id?(id) ->
        Map.merge(detail, from_id.(id))

      true ->
        detail
    end
  end

  defp present_id?(id) when id in [nil, ""], do: false
  defp present_id?(_), do: true

  defp resolve_all_line_typeaheads(params, company, user) do
    # Drops first (sales drives good), then loads
    drops =
      Map.new(params["drops"] || %{}, fn {k, drop} ->
        drop =
          drop
          |> stringify_keys_one()
          |> resolve_drop_typeahead("sales_title", company, user)
          |> resolve_drop_typeahead("good_name", company, user)
          |> resolve_drop_typeahead("location_name", company, user)
          |> resolve_drop_typeahead("supply_title", company, user)

        {k, drop}
      end)

    loads =
      Map.new(params["loads"] || %{}, fn {k, load} ->
        load =
          load
          |> stringify_keys_one()
          |> resolve_load_typeahead("supply_title", company, user)
          |> resolve_load_typeahead("good_name", company, user)
          |> resolve_load_typeahead("location_name", company, user)

        {k, load}
      end)

    params
    |> Map.put("loads", loads)
    |> Map.put("drops", drops)
  end

  # Ensure typeahead labels are populated from IDs (desk prefill may only have ids).
  defp backfill_all_line_labels(params, company, user) do
    resolve_all_line_typeaheads(params, company, user)
  end

  defp stringify_keys_one(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys_one(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <div>
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
        id="desk-trip-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
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
          <div :if={@form[:transport_mode].value == "agent"} class="w-[28%] grow shrink">
            <.input
              field={@form[:transport_agent_name]}
              label={gettext("Transport agent")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
            <.input type="hidden" field={@form[:transport_agent_id]} />
          </div>
        </div>

        <div class="flex flex-row flex-nowrap gap-1 mt-1">
          <div class="w-[88%]">
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

        <.drops_section
          form={@form}
          company_id={@current_company.id}
          user_id={@current_user.id}
          phx_target={@myself}
          show_errors={!!@form.source.action}
        />

        <.loads_section
          form={@form}
          company_id={@current_company.id}
          user_id={@current_user.id}
          phx_target={@myself}
          drop_good_ids={drop_good_ids(@form)}
          show_errors={!!@form.source.action}
        />

        <div class="mt-3 flex flex-wrap items-center justify-between gap-3">
          <%!-- Form actions (left) --%>
          <div class="flex flex-wrap gap-1">
            <.button :if={is_nil(@trip) or @trip.status not in ["completed", "cancelled"]}>
              {gettext("Save")}
            </.button>
            <.print_button
              :if={@live_action == :edit && @trip}
              doc_type="trading/trips"
              doc_id={@trip.id}
              company={@current_company}
              class="blue button"
            />
            <.live_component
              :if={@live_action == :edit && @trip}
              module={FullCircleWeb.LogLive.Component}
              current_company={@current_company}
              id={"log_#{@trip.id}"}
              show_log={false}
              entity="trading_trips"
              entity_id={@trip.id}
            />
            <button type="button" phx-click="close_modal" class="gray button">
              {gettext("Cancel")}
            </button>
          </div>
          <%!-- Status transitions (right) --%>
          <div
            :if={
              @live_action == :edit && @trip &&
                @trip.status in ["draft", "planned", "completed"]
            }
            class="flex flex-wrap items-center gap-1 sm:border-l sm:border-zinc-200 sm:pl-3"
          >
            <span class="text-xs font-medium text-zinc-500 mr-1">
              {gettext("Update status")}
            </span>
            <button
              :if={@trip.status in ["draft", "planned"]}
              type="button"
              phx-click="complete"
              phx-target={@myself}
              class="orange button"
              data-confirm={gettext("Complete this trip? Actuals will update balances.")}
            >
              {gettext("Complete trip")}
            </button>
            <button
              :if={@trip.status != "cancelled"}
              type="button"
              phx-click="cancel_trip"
              phx-target={@myself}
              class="red button"
              data-confirm={gettext("Cancel this trip?")}
            >
              {gettext("Cancel trip")}
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
