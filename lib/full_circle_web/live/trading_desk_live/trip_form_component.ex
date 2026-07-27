defmodule FullCircleWeb.TradingDeskLive.TripFormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Trading
  alias FullCircle.Trading.{Trip, TripLoad, TripDrop}
  alias FullCircle.Accounting
  alias FullCircle.Product
  alias FullCircle.HR
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
            good_unit: l.good && l.good.unit,
            location_name: location_label(l.location),
            supply_title: supply_label(l.supply_position),
            party_contact_id: l.supply_position && l.supply_position.supplier_id,
            trip_load_employees: put_crew_names(l.trip_load_employees)
        }
      end)

    drops =
      Enum.map(List.wrap(trip.drops), fn d ->
        %{
          d
          | good_name: d.good && d.good.name,
            good_unit: d.good && d.good.unit,
            location_name: location_label(d.location),
            sales_title: sales_label(d.sales_position),
            supply_title: supply_label(d.supply_position),
            party_contact_id: d.sales_position && d.sales_position.customer_id,
            trip_drop_employees: put_crew_names(d.trip_drop_employees)
        }
      end)

    %{trip | loads: loads, drops: drops}
  end

  defp put_crew_names(nil), do: []

  defp put_crew_names(rows) do
    Enum.map(List.wrap(rows), fn row ->
      %{row | employee_name: row.employee && row.employee.name}
    end)
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
      |> fill_down_crew_changesets(:loads, :trip_load_employees)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("add_drop", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:drops, %TripDrop{seq: next_seq(socket, :drops)})
      |> fill_down_crew_changesets(:drops, :trip_drop_employees)
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

  def handle_event("remove_load_crew", %{"line" => line, "crew" => crew}, socket) do
    cs =
      socket
      |> remove_nested_crew(:loads, :trip_load_employees, line, crew)
      |> fill_down_crew_changesets(:loads, :trip_load_employees)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("remove_drop_crew", %{"line" => line, "crew" => crew}, socket) do
    cs =
      socket
      |> remove_nested_crew(:drops, :trip_drop_employees, line, crew)
      |> fill_down_crew_changesets(:drops, :trip_drop_employees)

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
        {:noreply,
         put_flash(socket, :error, gettext("All loads and drops need actual quantity."))}

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
      {:ok, _trip, warnings} ->
        msg =
          if warnings == [] do
            gettext("Trip cancelled.")
          else
            gettext("Trip cancelled with warnings: ") <> Enum.join(warnings, "; ")
          end

        send(self(), {:desk_modal_saved, :trip, msg})
        {:noreply, socket}

      {:error, :has_invoices} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Cannot cancel: trip has a linked Invoice or PurInvoice. Unlink settlement first."
           )
         )}

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

  defp remove_nested_crew(socket, line_assoc, crew_assoc, line_idx, crew_idx) do
    line_i = if is_binary(line_idx), do: String.to_integer(line_idx), else: line_idx
    crew_s = to_string(crew_idx)
    cs = socket.assigns.form.source
    lines = Ecto.Changeset.get_assoc(cs, line_assoc) || []

    case Enum.at(lines, line_i) do
      nil ->
        cs |> Map.put(:action, :validate)

      line_cs ->
        line_cs =
          line_cs
          |> FullCircleWeb.Helpers.delete_line(crew_s, crew_assoc)
          |> Ecto.Changeset.put_change(:crew_locked, true)

        lines = List.replace_at(lines, line_i, line_cs)

        cs
        |> Ecto.Changeset.put_assoc(line_assoc, lines)
        |> Map.put(:action, :validate)
    end
  end

  defp crew_visible?(mode) when mode in ["company_own", "agent"], do: true
  defp crew_visible?(_), do: false

  # Copy crew from each locked line down onto following unlocked lines.
  defp fill_down_crew_changesets(cs, line_assoc, crew_assoc) do
    lines = Ecto.Changeset.get_assoc(cs, line_assoc) || []
    n = length(lines)

    if n == 0 do
      cs
    else
      new_lines =
        Enum.reduce(0..(n - 1)//1, lines, fn i, ls ->
          line = Enum.at(ls, i)

          cond do
            cs_line_deleted?(line) ->
              ls

            not cs_crew_locked?(line) ->
              ls

            true ->
              crew_params = crew_params_from_line_cs(line, crew_assoc)

              if i >= n - 1 do
                ls
              else
                Enum.reduce((i + 1)..(n - 1)//1, ls, fn j, ls2 ->
                  jl = Enum.at(ls2, j)

                  cond do
                    cs_line_deleted?(jl) ->
                      ls2

                    cs_crew_locked?(jl) ->
                      ls2

                    true ->
                      List.replace_at(
                        ls2,
                        j,
                        put_crew_params_on_line_cs(jl, crew_assoc, crew_params)
                      )
                  end
                end)
              end
          end
        end)

      Ecto.Changeset.put_assoc(cs, line_assoc, new_lines)
    end
  end

  defp cs_line_deleted?(%Ecto.Changeset{} = cs),
    do: Ecto.Changeset.get_field(cs, :delete) in [true, "true"]

  defp cs_line_deleted?(_), do: false

  defp cs_crew_locked?(%Ecto.Changeset{} = cs),
    do: Ecto.Changeset.get_field(cs, :crew_locked) in [true, "true"]

  defp cs_crew_locked?(_), do: false

  defp crew_params_from_line_cs(line_cs, crew_assoc) do
    (Ecto.Changeset.get_assoc(line_cs, crew_assoc) || [])
    |> Enum.reject(fn
      %Ecto.Changeset{} = c -> Ecto.Changeset.get_field(c, :delete) in [true, "true"]
      _ -> false
    end)
    |> Enum.with_index()
    |> Map.new(fn {crew_cs, i} ->
      {Integer.to_string(i),
       %{
         "employee_id" => Ecto.Changeset.get_field(crew_cs, :employee_id),
         "employee_name" => Ecto.Changeset.get_field(crew_cs, :employee_name)
       }}
    end)
  end

  defp put_crew_params_on_line_cs(line_cs, crew_assoc, crew_params) do
    module =
      case crew_assoc do
        :trip_load_employees -> FullCircle.Trading.TripLoadEmployee
        :trip_drop_employees -> FullCircle.Trading.TripDropEmployee
      end

    crew_cs =
      crew_params
      |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
      |> Enum.map(fn {_k, attrs} ->
        module.changeset(struct(module), attrs)
      end)

    line_cs
    |> Ecto.Changeset.put_assoc(crew_assoc, crew_cs)
    |> Ecto.Changeset.put_change(:crew_locked, false)
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
              %{id: id, value: name, unit: unit} ->
                %{"good_id" => id, "good_name" => name, "good_unit" => unit}

              %{id: id, value: name} ->
                %{"good_id" => id, "good_name" => name}

              _ ->
                %{}
            end,
            fn id ->
              case FullCircle.Repo.get(FullCircle.Product.Good, id) do
                %{name: name, unit: unit} -> %{"good_name" => name, "good_unit" => unit}
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
                  "good_unit" => s.good && s.good.unit,
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
                  "good_unit" => s.good && s.good.unit,
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
              %{id: id, value: name, unit: unit} ->
                %{"good_id" => id, "good_name" => name, "good_unit" => unit}

              %{id: id, value: name} ->
                %{"good_id" => id, "good_name" => name}

              _ ->
                %{}
            end,
            fn id ->
              case FullCircle.Repo.get(FullCircle.Product.Good, id) do
                %{name: name, unit: unit} -> %{"good_name" => name, "good_unit" => unit}
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
                  "good_unit" => s.good && s.good.unit,
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
                  "good_unit" => s.good && s.good.unit,
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
          |> absorb_crew_add("trip_drop_employees", company, user)
          |> backfill_crew_names("trip_drop_employees", company, user)

        {k, drop}
      end)
      |> fill_down_crew_params("trip_drop_employees")

    loads =
      Map.new(params["loads"] || %{}, fn {k, load} ->
        load =
          load
          |> stringify_keys_one()
          |> resolve_load_typeahead("supply_title", company, user)
          |> resolve_load_typeahead("good_name", company, user)
          |> resolve_load_typeahead("location_name", company, user)
          |> absorb_crew_add("trip_load_employees", company, user)
          |> backfill_crew_names("trip_load_employees", company, user)

        {k, load}
      end)
      |> fill_down_crew_params("trip_load_employees")

    params
    |> Map.put("loads", loads)
    |> Map.put("drops", drops)
  end

  # When crew_add_name resolves to an employee, append to crew assoc, lock this line,
  # and clear the field (fill-down runs after all lines are processed).
  defp absorb_crew_add(detail, crew_key, company, user) do
    name = detail["crew_add_name"] |> to_string() |> String.trim()

    if name == "" do
      detail
    else
      case HR.get_employee_by_name(name, company, user) do
        %{id: id, name: ename} ->
          crew = normalize_crew_map(detail[crew_key])

          already? =
            Enum.any?(crew, fn {_k, row} ->
              row = stringify_keys_one(row)

              to_string(row["employee_id"]) == to_string(id) and
                row["delete"] not in [true, "true"]
            end)

          crew =
            if already? do
              crew
            else
              idx = next_crew_index(crew)
              Map.put(crew, idx, %{"employee_id" => id, "employee_name" => ename})
            end

          detail
          |> Map.put(crew_key, crew)
          |> Map.put("crew_add_name", "")
          |> Map.put("crew_locked", true)

        nil ->
          # Keep typed text so user can finish the name; id not added yet
          detail
      end
    end
  end

  # For each locked line (user-edited crew), copy its active crew onto following
  # unlocked lines. Later locked lines win for lines below them.
  defp fill_down_crew_params(lines_map, crew_key) when is_map(lines_map) do
    keys =
      lines_map
      |> Map.keys()
      |> Enum.sort_by(fn
        k when is_integer(k) -> k
        k when is_binary(k) -> String.to_integer(k)
      end)

    Enum.reduce(keys, lines_map, fn i, map ->
      line = stringify_keys_one(Map.get(map, i) || %{})

      cond do
        line_params_deleted?(line) ->
          map

        not truthy_locked?(line["crew_locked"]) ->
          map

        true ->
          crew = active_crew_snapshot(line[crew_key])
          following = Enum.drop_while(keys, &(&1 != i)) |> Enum.drop(1)

          Enum.reduce(following, map, fn j, m ->
            jl = stringify_keys_one(Map.get(m, j) || %{})

            cond do
              line_params_deleted?(jl) ->
                m

              truthy_locked?(jl["crew_locked"]) ->
                m

              true ->
                Map.put(
                  m,
                  j,
                  jl
                  |> Map.put(crew_key, crew)
                  |> Map.put("crew_locked", false)
                )
            end
          end)
      end
    end)
  end

  defp fill_down_crew_params(other, _), do: other

  defp line_params_deleted?(line), do: line["delete"] in [true, "true"]

  defp truthy_locked?(v), do: v in [true, "true"]

  defp active_crew_snapshot(crew) do
    crew
    |> normalize_crew_map()
    |> Enum.filter(fn {_k, row} ->
      row = stringify_keys_one(row)
      row["delete"] not in [true, "true"] and present_id?(row["employee_id"])
    end)
    |> Enum.with_index()
    |> Map.new(fn {{_k, row}, i} ->
      row = stringify_keys_one(row)

      {Integer.to_string(i),
       %{
         "employee_id" => row["employee_id"],
         "employee_name" => row["employee_name"]
       }}
    end)
  end

  defp backfill_crew_names(detail, crew_key, _company, _user) do
    crew =
      detail
      |> Map.get(crew_key, %{})
      |> normalize_crew_map()
      |> Map.new(fn {k, row} ->
        row = stringify_keys_one(row)
        id = row["employee_id"]
        name = row["employee_name"] |> to_string() |> String.trim()

        row =
          cond do
            name != "" ->
              row

            present_id?(id) ->
              case FullCircle.Repo.get(FullCircle.HR.Employee, id) do
                %{name: n} -> Map.put(row, "employee_name", n)
                _ -> row
              end

            true ->
              row
          end

        {k, row}
      end)

    Map.put(detail, crew_key, crew)
  end

  defp normalize_crew_map(map) when is_map(map), do: stringify_map(map)

  defp normalize_crew_map(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Map.new(fn {item, i} -> {Integer.to_string(i), stringify_val(item)} end)
  end

  defp normalize_crew_map(_), do: %{}

  defp next_crew_index(crew) when is_map(crew) do
    crew
    |> Map.keys()
    |> Enum.map(fn
      k when is_integer(k) -> k
      k when is_binary(k) -> String.to_integer(k)
    end)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
    |> Integer.to_string()
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
          show_crew={crew_visible?(@form[:transport_mode].value)}
        />

        <.loads_section
          form={@form}
          company_id={@current_company.id}
          user_id={@current_user.id}
          phx_target={@myself}
          drop_good_ids={drop_good_ids(@form)}
          show_errors={!!@form.source.action}
          show_crew={crew_visible?(@form[:transport_mode].value)}
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
              :if={@trip.status != "cancelled" and not Trading.trip_has_settlement_docs?(@trip)}
              type="button"
              id="desk-trip-cancel"
              phx-click="cancel_trip"
              phx-target={@myself}
              class="red button"
              data-confirm={gettext("Cancel this trip?")}
            >
              {gettext("Cancel trip")}
            </button>
            <span
              :if={@trip.status == "completed" and Trading.trip_has_settlement_docs?(@trip)}
              id="desk-trip-cancel-blocked"
              class="text-xs text-zinc-500 max-w-[14rem]"
              title={gettext("Unlink Invoice / PurInvoice settlement before cancelling this trip.")}
            >
              {gettext("Cancel blocked (settled)")}
            </span>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
