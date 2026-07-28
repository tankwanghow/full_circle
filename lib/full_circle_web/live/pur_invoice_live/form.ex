defmodule FullCircleWeb.PurInvoiceLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Billing
  alias FullCircle.Billing.{PurInvoice}

  @impl true
  def mount(params, _session, socket) do
    id = params["invoice_id"]
    obj = params["obj"]

    socket =
      case socket.assigns.live_action do
        :new ->
          cond do
            obj ->
              mount_new(obj, socket)

            params["trading_loads"] not in [nil, ""] ->
              mount_new_from_trading(socket, params)

            params["trading_transport_drops"] not in [nil, ""] ->
              mount_new_from_transport(socket, params)

            params["egg"] ->
              mount_new_from_egg(socket, params)

            true ->
              mount_new(socket)
          end

        :edit ->
          mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign_new(:trading_load_ids, fn -> [] end)
     |> assign_new(:trading_transport_drop_ids, fn -> [] end)
     # Attach direction — lines the clerk ticked on the trading panel, linked
     # inside the save Multi. Distinct from the push-direction ids above, which
     # arrive prefilled from the settlement board.
     |> assign_new(:trading_link_load_ids, fn -> [] end)
     |> assign_new(:trading_link_transport_drop_ids, fn -> [] end)
     |> assign_new(:e_inv_payable, fn -> nil end)
     |> assign_new(:trading_settlement, fn ->
       %{
         linked?: false,
         line_count: 0,
         actual_sum: 0,
         trip_refs: [],
         supplier_load_count: 0,
         transport_drop_count: 0
       }
     end)
     |> assign_new(:e_inv_preview, fn -> nil end)
     |> assign(
       settings:
         FullCircle.Sys.load_settings(
           "PurInvoice",
           socket.assigns.current_company,
           socket.assigns.current_user
         )
     )}
  end

  defp mount_new(socket) do
    attrs = %{pur_invoice_no: "...new..."}

    cs =
      Billing.make_changeset(
        PurInvoice,
        %PurInvoice{},
        attrs,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> FullCircleWeb.Helpers.add_line(:pur_invoice_details)

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(trading_load_ids: [])
    |> assign(trading_transport_drop_ids: [])
    |> assign(page_title: gettext("New Purchase Invoice"))
    |> assign(matched_trans: [])
    |> assign(:form, to_form(cs))
  end

  defp mount_new_from_trading(socket, params) do
    ids = parse_id_list(params["trading_loads"])

    {attrs, load_ids, flash} =
      case FullCircle.Trading.build_pur_invoice_attrs_from_load_ids(
             ids,
             socket.assigns.current_company,
             socket.assigns.current_user
           ) do
        {:ok, trading_attrs} ->
          {trading_attrs, ids, nil}

        {:error, :mixed_suppliers} ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("Selected loads must belong to the same supplier")}

        {:error, :ineligible_loads} ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("Some loads are no longer eligible for billing")}

        :not_authorise ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("You are not authorised to perform this action")}

        {:error, _} ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("Cannot prefill purchase invoice from trading loads")}
      end

    finish_trading_prefill(socket, attrs, flash,
      trading_load_ids: load_ids,
      trading_transport_drop_ids: []
    )
  end

  defp mount_new_from_transport(socket, params) do
    ids = parse_id_list(params["trading_transport_drops"])

    {attrs, drop_ids, flash} =
      case FullCircle.Trading.build_pur_invoice_attrs_from_transport_drop_ids(
             ids,
             socket.assigns.current_company,
             socket.assigns.current_user
           ) do
        {:ok, trading_attrs} ->
          {trading_attrs, ids, nil}

        {:error, :mixed_agents} ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("Selected haul lines must belong to the same transport agent")}

        {:error, :ineligible_transport} ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("Some haul lines are no longer eligible for billing")}

        :not_authorise ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("You are not authorised to perform this action")}

        {:error, _} ->
          {%{"pur_invoice_no" => "...new..."}, [],
           gettext("Cannot prefill purchase invoice from transport lines")}
      end

    finish_trading_prefill(socket, attrs, flash,
      trading_load_ids: [],
      trading_transport_drop_ids: drop_ids
    )
  end

  defp finish_trading_prefill(socket, attrs, flash, assigns) do
    cs =
      Billing.make_changeset(
        PurInvoice,
        %PurInvoice{},
        attrs,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      if Ecto.Changeset.get_assoc(cs, :pur_invoice_details) == [] do
        FullCircleWeb.Helpers.add_line(cs, :pur_invoice_details)
      else
        cs
      end

    socket =
      socket
      |> assign(live_action: :new)
      |> assign(id: "new")
      |> assign(assigns)
      |> assign(page_title: gettext("New Purchase Invoice"))
      |> assign(matched_trans: [])
      |> assign_egg_link(%{}, :purchase)
      |> assign(:form, to_form(cs))

    if flash, do: put_flash(socket, :error, flash), else: socket
  end

  defp parse_id_list(nil), do: []
  defp parse_id_list(""), do: []

  defp parse_id_list(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp mount_new_from_egg(socket, params) do
    egg_quantities = parse_egg_quantities(params["egg"])

    details =
      Billing.build_purchase_details_from_egg_order(
        egg_quantities,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    attrs = %{
      pur_invoice_no: "...new...",
      contact_name: params["contact_name"],
      contact_id: blank_id(params["contact_id"]),
      pur_invoice_date: params["date"],
      load_date: params["date"],
      pur_invoice_details: details
    }

    cs =
      Billing.make_changeset(
        PurInvoice,
        %PurInvoice{},
        attrs,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      if Ecto.Changeset.get_assoc(cs, :pur_invoice_details) == [] do
        FullCircleWeb.Helpers.add_line(cs, :pur_invoice_details)
      else
        cs
      end

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Purchase Invoice"))
    |> assign(matched_trans: [])
    |> assign_egg_link(params, :purchase)
    |> assign(:form, to_form(cs))
  end

  defp blank_id(nil), do: nil
  defp blank_id(""), do: nil
  defp blank_id(id), do: id

  defp assign_egg_link(socket, params, side) do
    if params["egg"] do
      socket
      |> assign(:egg_detail_id, blank_id(params["egg_detail_id"]))
      |> assign(:egg_contact_name, params["contact_name"] || "")
      |> assign(:egg_load_date, params["date"])
      |> assign(:egg_side, side)
    else
      socket
      |> assign(:egg_detail_id, nil)
      |> assign(:egg_contact_name, nil)
      |> assign(:egg_load_date, nil)
      |> assign(:egg_side, nil)
    end
  end

  defp maybe_attach_egg_planned(socket, obj, params) do
    if socket.assigns[:egg_detail_id] || socket.assigns[:egg_load_date] do
      load_date =
        Map.get(obj, :load_date) || Map.get(obj, :pur_invoice_date) ||
          socket.assigns[:egg_load_date]

      FullCircle.EggStock.attach_contact_from_document(
        socket.assigns.current_company,
        socket.assigns.current_user,
        %{
          detail_id: socket.assigns[:egg_detail_id],
          load_date: parse_date(load_date),
          side: socket.assigns[:egg_side] || :purchase,
          original_name: socket.assigns[:egg_contact_name],
          contact_id: obj.contact_id,
          contact_name: params["contact_name"] || obj.contact_name
        }
      )
    end

    socket
  end

  defp parse_date(%Date{} = d), do: d
  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_egg_quantities(egg_str) do
    egg_str
    |> String.split(",")
    |> Enum.map(fn part ->
      case String.split(part, ":", parts: 2) do
        [grade, qty] -> {URI.decode(grade), qty}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp mount_new(obj, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    seed =
      Jason.decode!(obj)
      |> FullCircle.EInvMetas.Prefill.build(com, user, :pur_invoice_details)

    attrs =
      Map.merge(seed.attrs, %{
        pur_invoice_no: "...new...",
        pur_invoice_date: seed.issue_date,
        due_date: seed.issue_date
      })

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Purchase Invoice"))
    |> assign(matched_trans: [])
    |> assign(e_inv_supplier_ids: seed.supplier_ids)
    |> assign(e_inv_payable: seed.payable)
    |> assign(e_inv_preview: seed.preview)
    |> then(fn s ->
      case Enum.reject(seed.warnings, &is_nil/1) do
        [] -> s
        msgs -> put_flash(s, :warn, Enum.join(msgs, " "))
      end
    end)
    |> assign(
      :form,
      to_form(
        Billing.make_changeset(
          PurInvoice,
          %PurInvoice{},
          attrs,
          com,
          user
        )
      )
    )
  end

  defp e_inv_variance(form, payable) do
    form.source
    |> Ecto.Changeset.fetch_field!(:pur_invoice_amount)
    |> FullCircle.EInvMetas.Prefill.variance(payable)
  end

  # After a bill is created from an e-invoice, stamp the supplier's TIN and BRN
  # onto the contact if it has none, so the next e-invoice from them resolves on
  # identifier instead of on a name spelling that may never match.
  defp maybe_learn_supplier_ids(socket, obj) do
    case socket.assigns[:e_inv_supplier_ids] do
      {tin, brn} ->
        FullCircle.Accounting.learn_contact_identifiers(
          obj.contact_id,
          tin,
          brn,
          socket.assigns.current_company,
          socket.assigns.current_user
        )

      _ ->
        nil
    end

    socket
  end

  defp mount_edit(socket, id) do
    company = socket.assigns.current_company

    object =
      Billing.get_pur_invoice!(
        id,
        company,
        socket.assigns.current_user
      )

    settlement = FullCircle.Trading.pur_invoice_settlement_info(id, company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(trading_settlement: settlement)
    |> assign(matched_trans: Billing.get_matcher_by("PurInvoice", id))
    |> assign(page_title: gettext("Edit Purchase Invoice") <> " " <> object.pur_invoice_no)
    |> assign(
      :form,
      to_form(
        Billing.make_changeset(
          PurInvoice,
          object,
          %{},
          company,
          socket.assigns.current_user
        )
      )
    )
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:pur_invoice_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> PurInvoice.compute_fields()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :pur_invoice_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> PurInvoice.compute_fields()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["settings", id, "value"], "settings" => new_settings},
        socket
      ) do
    settings = socket.assigns.settings

    setting = Enum.find(settings, fn x -> x.id == id end)

    %{"value" => value} = Map.get(new_settings, id)

    setting = FullCircle.Sys.update_setting(setting, value)

    settings =
      Enum.reject(settings, fn x -> x.id == id end)
      |> Enum.concat([setting])
      |> Enum.sort_by(& &1.id)

    {:noreply,
     socket
     |> assign(settings: settings)}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["pur_invoice", "contact_name"], "pur_invoice" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_ids(
        socket,
        params,
        "contact_name",
        %{"contact_id" => :id, "tax_id" => :tax_id, "reg_no" => :reg_no},
        &FullCircle.Accounting.get_contact_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["pur_invoice", "pur_invoice_details", id, "good_name"],
          "pur_invoice" => params
        },
        socket
      ) do
    detail = params["pur_invoice_details"][id]

    {detail, socket, good} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "good_name",
        "good_id",
        &FullCircle.Product.get_good_by_name/3
      )

    detail =
      Map.merge(detail, %{
        "account_name" => Util.attempt(good, :purchase_account_name),
        "account_id" => Util.attempt(good, :purchase_account_id),
        "tax_code_name" => Util.attempt(good, :purchase_tax_code_name),
        "tax_code_id" => Util.attempt(good, :purchase_tax_code_id),
        "tax_rate" => Util.attempt(good, :purchase_tax_rate),
        "package_name" => Util.attempt(good, :package_name),
        "package_id" => Util.attempt(good, :package_id),
        "unit" => Util.attempt(good, :unit),
        "unit_multiplier" => Util.attempt(good, :unit_multiplier) || 0,
        "package_qty" => 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("pur_invoice_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["pur_invoice", "pur_invoice_details", id, "package_name"],
          "pur_invoice" => params
        },
        socket
      ) do
    detail = params["pur_invoice_details"][id]
    terms = detail["package_name"]

    pack =
      FullCircle.Product.get_packaging_by_name(
        String.trim(terms),
        detail["good_id"]
      )

    detail =
      Map.merge(detail, %{
        "package_id" => Util.attempt(pack, :id) || nil,
        "unit_multiplier" => Util.attempt(pack, :unit_multiplier) || 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("pur_invoice_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["pur_invoice", "pur_invoice_details", id, "account_name"],
          "pur_invoice" => params
        },
        socket
      ) do
    detail = params["pur_invoice_details"][id]

    {detail, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "account_name",
        "account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("pur_invoice_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["pur_invoice", "pur_invoice_details", id, "tax_code_name"],
          "pur_invoice" => params
        },
        socket
      ) do
    detail = params["pur_invoice_details"][id]

    {detail, socket, taxcode} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "tax_code_name",
        "tax_code_id",
        &FullCircle.Accounting.get_tax_code_by_code/3
      )

    detail =
      Map.merge(detail, %{
        "tax_rate" => Util.attempt(taxcode, :rate) || 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("pur_invoice_details", id, detail)

    validate(params, socket)
  end

  def handle_event("validate", %{"pur_invoice" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"pur_invoice" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("show_e_inv", _, socket) do
    uuid = socket.assigns.form[:e_inv_uuid].value

    preview =
      case FullCircle.EInvMetas.get_full_e_invoice(
             uuid,
             socket.assigns.current_company,
             socket.assigns.current_user
           ) do
        {:ok, body} ->
          parsed = FullCircle.EInvMetas.parse_e_invoice_document(body)
          {:ok, parsed}

        {:error, reason} ->
          {:error, reason}
      end

    {:noreply, socket |> assign(e_inv_preview: preview)}
  end

  @impl true
  def handle_event("close_e_inv_preview", _, socket) do
    {:noreply, socket |> assign(e_inv_preview: nil)}
  end

  def handle_event("unlink_trading_settlement", _, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    pinv = socket.assigns.form.data

    case FullCircle.Trading.unlink_pur_invoice_settlement(pinv, company, user) do
      {:ok, %{loads_unlinked: n_l, transport_unlinked: n_t}} ->
        settlement = FullCircle.Trading.pur_invoice_settlement_info(pinv.id, company)

        {:noreply,
         socket
         |> assign(trading_settlement: settlement)
         |> put_flash(
           :info,
           gettext(
             "Unlinked %{loads} load(s) and %{hauls} transport haul(s). They can be settled again.",
             loads: n_l,
             hauls: n_t
           )
         )}

      {:error, :not_linked} ->
        {:noreply,
         put_flash(socket, :info, gettext("No trading links on this purchase invoice."))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to unlink trading settlement"))}
    end
  end

  @impl true
  def handle_info({:trading_attach_selection, contact_id, load_ids, transport_drop_ids}, socket) do
    {:noreply,
     socket
     |> assign(trading_link_contact_id: contact_id)
     |> assign(trading_link_load_ids: load_ids)
     |> assign(trading_link_transport_drop_ids: transport_drop_ids)}
  end

  defp save(socket, :new, params) do
    params = params |> Map.merge(%{"pur_invoice_no" => "...new..."})
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    load_ids = socket.assigns[:trading_load_ids] || []
    transport_ids = socket.assigns[:trading_transport_drop_ids] || []

    result =
      cond do
        load_ids != [] ->
          FullCircle.Trading.create_pur_invoice_from_loads(load_ids, params, company, user)

        transport_ids != [] ->
          FullCircle.Trading.create_pur_invoice_from_transport_drops(
            transport_ids,
            params,
            company,
            user
          )

        true ->
          Billing.create_pur_invoice(
            params,
            company,
            user,
            attach_links_fun(socket, params, company, user)
          )
      end

    case result do
      {:ok, %{create_pur_invoice: obj}} ->
        socket =
          socket
          |> maybe_attach_egg_planned(obj, params)
          |> maybe_learn_supplier_ids(obj)

        flash =
          cond do
            load_ids != [] ->
              gettext("Purchase invoice created and trading loads linked successfully.")

            transport_ids != [] ->
              gettext("Purchase invoice created and transport haul lines linked successfully.")

            attached?(socket, params) ->
              gettext("Purchase Invoice created and trading lines linked successfully.")

            true ->
              gettext("Purchase Invoice created successfully.")
          end

        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{company.id}/PurInvoice/#{obj.id}/edit")
         |> put_flash(:info, flash)
         |> maybe_warn_unbilled_trading(obj, params, company, user)}

      {:error, :loads_already_billed} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Some loads were already billed. Purchase invoice was not created.")
         )}

      {:error, :transport_already_billed} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Some haul lines were already billed. Purchase invoice was not created.")
         )}

      {:error, :ineligible_loads} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Some loads are no longer eligible for billing"))}

      {:error, :ineligible_transport} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Some haul lines are no longer eligible for billing"))}

      {:error, :mixed_suppliers} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Selected loads must belong to the same supplier"))}

      {:error, :mixed_agents} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Selected haul lines must belong to the same transport agent")
         )}

      {:error, step, reason, _} when step in [:link_trading_loads, :link_trading_transport] ->
        {:noreply, put_flash(socket, :error, trading_link_error(reason))}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    pinv = socket.assigns.form.data
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if FullCircle.Trading.contact_change_blocked_for_pur_invoice?(pinv, params) do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "Supplier/agent cannot be changed while this purchase invoice is linked to trading. Unlink trading settlement first."
         )
       )}
    else
      do_update_pur_invoice(socket, pinv, params, company, user)
    end
  end

  defp save(socket, :match, params) do
    case Billing.match_pur_invoice(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_pur_invoice: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/PurInvoice/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Purchase Invoice matched successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :unmatch, params) do
    case Billing.match_pur_invoice(
           socket.assigns.form.data,
           Map.merge(params, %{"e_inv_uuid" => nil, "e_inv_long_id" => nil, "e_inv_info" => nil}),
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_pur_invoice: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/PurInvoice/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Purchase Invoice unmatched successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp do_update_pur_invoice(socket, pinv, params, company, user) do
    case Billing.update_pur_invoice(
           pinv,
           params,
           company,
           user,
           attach_links_fun(socket, params, company, user, :update_pur_invoice)
         ) do
      {:ok, %{update_pur_invoice: obj}} ->
        flash =
          if attached?(socket, params) do
            gettext("Purchase Invoice updated and trading lines linked successfully.")
          else
            gettext("Purchase Invoice updated successfully.")
          end

        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{company.id}/PurInvoice/#{obj.id}/edit")
         |> put_flash(:info, flash)}

      {:error, step, reason, _} when step in [:link_trading_loads, :link_trading_transport] ->
        {:noreply, put_flash(socket, :error, trading_link_error(reason))}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:error, :has_matchers} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "Cannot save: this document has been matched by another document. Remove the matching Receipt/Payment/Credit/Debit Note first."
           )
         )}

      {:error, :closed} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Cannot save: this document is in a closed accounting period.")
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  # --- Trading attach (linking an existing/e-invoice bill to trading lines) ---

  defp attach_links_fun(socket, params, company, user, pinv_key \\ :create_pur_invoice) do
    {load_ids, drop_ids} = attach_ids(socket, params)

    &FullCircle.Trading.attach_links_multi(&1, pinv_key, load_ids, drop_ids, company, user)
  end

  # A selection is only valid for the contact it was made against. Switching
  # supplier unmounts the panel, so the parent has to drop the ids itself —
  # otherwise the save would fail with :supplier_mismatch instead of quietly
  # forgetting lines the clerk can no longer see.
  defp attach_ids(socket, params) do
    if blank_id(params["contact_id"]) == socket.assigns[:trading_link_contact_id] do
      {socket.assigns[:trading_link_load_ids] || [],
       socket.assigns[:trading_link_transport_drop_ids] || []}
    else
      {[], []}
    end
  end

  defp attached?(socket, params) do
    attach_ids(socket, params) != {[], []}
  end

  defp trading_link_error(:loads_already_billed),
    do: gettext("Some loads were already billed by someone else. Nothing was saved.")

  defp trading_link_error(:transport_already_billed),
    do: gettext("Some haul lines were already billed by someone else. Nothing was saved.")

  defp trading_link_error(:ineligible_loads),
    do: gettext("Some loads are no longer eligible for billing")

  defp trading_link_error(:ineligible_transport),
    do: gettext("Some haul lines are no longer eligible for billing")

  defp trading_link_error(:mixed_suppliers),
    do: gettext("Selected loads must belong to the same supplier")

  defp trading_link_error(:mixed_agents),
    do: gettext("Selected haul lines must belong to the same transport agent")

  defp trading_link_error(:supplier_mismatch),
    do: gettext("Selected loads belong to a different supplier than this bill")

  defp trading_link_error(:agent_mismatch),
    do: gettext("Selected haul lines belong to a different transport agent than this bill")

  defp trading_link_error(:not_authorise),
    do: gettext("You are not authorised to perform this action")

  defp trading_link_error(_), do: gettext("Failed to link trading lines")

  # Nudge when a bill is saved leaving this contact's trading lines unbilled.
  # Only on create, and only when something is actually billable — plenty of
  # purchases from a grain supplier (bags, fuel, repairs) are not trading.
  defp maybe_warn_unbilled_trading(socket, obj, params, company, user) do
    if attached?(socket, params) or is_nil(obj.contact_id) do
      socket
    else
      case FullCircle.Trading.billable_line_counts(obj.contact_id, company, user) do
        %{total: 0} ->
          socket

        %{total: n} ->
          put_flash(
            socket,
            :warn,
            gettext(
              "%{n} trading line(s) for this supplier are still unbilled. Open this bill and attach them if it settles any of them.",
              n: n
            )
          )
      end
    end
  end

  # Quantity across the keyed lines, for the panel's advisory variance strip.
  defp bill_quantity(form) do
    form.source
    |> Ecto.Changeset.fetch_field!(:pur_invoice_details)
    |> Enum.reject(&(Map.get(&1, :delete) == true))
    |> Enum.reduce(Decimal.new(0), fn d, acc ->
      Decimal.add(acc, d.quantity || Decimal.new(0))
    end)
  end

  defp validate(params, socket) do
    if socket.assigns.live_action == :edit and
         FullCircle.Trading.contact_change_blocked_for_pur_invoice?(
           socket.assigns.form.data,
           params
         ) do
      params =
        params
        |> Map.put("contact_id", socket.assigns.form.data.contact_id)
        |> Map.put(
          "contact_name",
          socket.assigns.form.data.contact_name || socket.assigns.form[:contact_name].value
        )

      changeset =
        Billing.make_changeset(
          PurInvoice,
          socket.assigns.form.data,
          params,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
        |> Map.put(:action, socket.assigns.live_action)
        |> Ecto.Changeset.add_error(
          :contact_name,
          gettext("locked while linked to trading — unlink first")
        )

      {:noreply, assign(socket, form: to_form(changeset))}
    else
      changeset =
        Billing.make_changeset(
          PurInvoice,
          socket.assigns.form.data,
          params,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
        |> Map.put(:action, socket.assigns.live_action)

      {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto border rounded-lg border-pink-500 bg-pink-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.error_box changeset={@form.source} />
      <div
        :if={@live_action == :edit and @trading_settlement.linked?}
        class="mb-3 rounded border border-amber-600 bg-amber-50 px-3 py-2 text-sm"
        id="trading-settlement-banner"
      >
        <p class="font-medium text-amber-900">
          {gettext("Linked to trading settlement")}
        </p>
        <p class="text-amber-800 mt-1">
          {gettext(
            "%{n} line(s) · %{mt} MT · trips: %{trips}. Party is locked. Unlink if the match was wrong; commercial qty/price edits are allowed.",
            n: @trading_settlement.line_count,
            mt: @trading_settlement.actual_sum,
            trips: Enum.join(@trading_settlement.trip_refs, ", ")
          )}
        </p>
        <button
          type="button"
          id="unlink-trading-settlement"
          phx-click="unlink_trading_settlement"
          data-confirm={
            gettext(
              "Unlink this purchase invoice from trading loads/hauls? Lines will reappear on the settlement queue."
            )
          }
          class="mt-2 orange button text-sm"
        >
          {gettext("Unlink trading settlement")}
        </button>
      </div>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        phx-hook="ctrlEnterAddDetail"
      >
        <.input type="hidden" field={@form[:pur_invoice_no]} />
        <input type="hidden" id="live_action" value={@live_action} />
        <div class="flex flex-row flex-nowrap">
          <div class="w-1/4 grow shrink">
            <.input type="hidden" field={@form[:contact_id]} />
            <.input
              field={@form[:contact_name]}
              label={gettext("Supplier")}
              phx-hook={if(@trading_settlement.linked?, do: nil, else: "tributeAutoComplete")}
              readonly={@trading_settlement.linked?}
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="grow shrink">
            <.input field={@form[:reg_no]} label={gettext("Reg No")} readonly tabindex="-1" />
          </div>
          <div class="grow shrink">
            <.input field={@form[:tax_id]} label={gettext("Tax Id")} readonly tabindex="-1" />
          </div>
          <div class="grow shrink">
            <.input field={@form[:pur_invoice_date]} label={gettext("Invoice Date")} type="date" />
          </div>
          <div class="grow shrink">
            <.input field={@form[:load_date]} label={gettext("Load Date")} type="date" />
          </div>
          <div class="grow shrink">
            <.input field={@form[:due_date]} label={gettext("Due Date")} type="date" />
          </div>
          <div class="w-1/4 grow shrink">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
        </div>

        <div class="flex flex-row flex-nowrap mt-2">
          <div class="grow shrink">
            <.input
              field={@form[:loader_tags]}
              label={gettext("Loader Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=loader_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:loader_wages_tags]}
              label={gettext("Loader Wages Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=loader_wages_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:delivery_man_tags]}
              label={gettext("Delivery Man Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=delivery_man_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:delivery_wages_tags]}
              label={gettext("Delivery Wages Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=delivery_wages_tags&tag="}
            />
          </div>
        </div>

        <div class="flex flex-row flex-nowrap mt-2 w-[92%]">
          <div class="w-[15%]">
            <.input field={@form[:e_inv_internal_id]} label={gettext("E Invoice Internal Id")} />
          </div>
          <div class="w-[20%]">
            <.input field={@form[:e_inv_uuid]} label={gettext("E Invoice UUID")} />
          </div>
          <div
            :if={is_nil(@form[:e_inv_uuid].value)}
            class="text-blue-600 hover:font-medium w-[20%] ml-5 mt-6"
          >
            <.link target="_blank" href={"#{@einv_portal}/newdocument"}>
              {gettext("New E-Invoice")}
            </.link>
          </div>
          <div
            :if={!is_nil(@form[:e_inv_uuid].value)}
            class="text-blue-600 hover:font-medium ml-5 mt-6"
          >
            <.link
              target="_blank"
              href={"#{@einv_portal}/documents/#{@form[:e_inv_uuid].value}"}
            >
              Open E-Invoice
            </.link>
          </div>
          <div
            :if={
              @live_action == :new and !is_nil(@form[:e_inv_uuid].value) and is_nil(@e_inv_preview)
            }
            class="ml-3 mt-5"
          >
            <.link phx-click="show_e_inv" class="blue button text-sm">
              {gettext("Show E-Invoice")}
            </.link>
          </div>
          <div class="shrink-0 ml-2 mt-1">
            <% {url, qrcode} =
              FullCircle.Helpers.e_invoice_validation_url_qrcode(@form.source.data, 1) %>
            <.link target="_blank" href={url}>
              {qrcode |> raw}
            </.link>
          </div>
        </div>

        <.live_component
          :if={
            @live_action in [:new, :edit] and @trading_load_ids == [] and
              @trading_transport_drop_ids == [] and
              not is_nil(blank_id(@form[:contact_id].value))
          }
          module={FullCircleWeb.PurInvoiceLive.TradingAttachComponent}
          id="trading-attach"
          current_company={@current_company}
          current_user={@current_user}
          contact_id={blank_id(@form[:contact_id].value)}
          bill_date={@form[:pur_invoice_date].value}
          bill_qty={bill_quantity(@form)}
        />

        <.live_component
          module={FullCircleWeb.InvoiceLive.DetailComponent}
          id="pur_invoice_details"
          klass=""
          settings={@settings}
          doc_name="PurInvoice"
          detail_name={:pur_invoice_details}
          form={@form}
          doc_good_amount={:pur_invoice_good_amount}
          doc_tax_amount={:pur_invoice_tax_amount}
          doc_detail_amount={:pur_invoice_amount}
          taxcodetype="purtaxcode"
          current_company={@current_company}
          current_user={@current_user}
          matched_trans={@matched_trans}
        />

        <div :if={@e_inv_payable} class="flex flex-row">
          <% variance = e_inv_variance(@form, @e_inv_payable) %>
          <div class="grow"></div>
          <div class={[
            "w-[10%] text-right px-1",
            if(variance, do: "text-red-600 font-semibold", else: "text-green-600")
          ]}>
            {gettext("E-Invoice")}
          </div>
          <div class={[
            "detail-amt-col text-right px-1",
            if(variance, do: "text-red-600 font-semibold", else: "text-green-600")
          ]}>
            {@e_inv_payable |> Number.Delimit.number_to_delimited()}
            <div :if={variance} class="text-xs">
              {gettext("out by")} {variance |> Number.Delimit.number_to_delimited()}
            </div>
          </div>
          <div class="detail-setting-col" />
        </div>

        <div class="flex flex-row justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="PurInvoice"
          />
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="pur_invoices"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="PurInvoice"
            doc_no={@form.data.pur_invoice_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>

      <div
        :if={@live_action == :new and @e_inv_preview}
        class="mt-4 border rounded-lg border-blue-500 bg-blue-50 p-4"
      >
        <div class="flex justify-between items-center mb-3">
          <p class="text-xl font-medium">{gettext("E-Invoice Document")}</p>
          <.link phx-click="close_e_inv_preview" class="orange button text-sm">
            {gettext("Close")}
          </.link>
        </div>
        <%= case @e_inv_preview do %>
          <% {:ok, parsed} -> %>
            <div class="grid grid-cols-2 gap-4 text-sm">
              <div class="border rounded p-3 bg-white">
                <p class="font-bold mb-2">{gettext("Supplier")}</p>
                <p class="font-medium">{parsed.supplier_name}</p>
                <p>TIN: {parsed.supplier_tin}</p>
                <p>BRN: {parsed.supplier_brn}</p>
              </div>
              <div class="border rounded p-3 bg-white">
                <p class="font-bold mb-2">{gettext("Document Info")}</p>
                <p><span class="font-bold">{gettext("Internal ID")}:</span> {parsed.internal_id}</p>
                <p><span class="font-bold">{gettext("Issue Date")}:</span> {parsed.issue_date}</p>
                <p><span class="font-bold">{gettext("Currency")}:</span> {parsed.currency}</p>
                <p><span class="font-bold">{gettext("Type")}:</span> {parsed.type_code}</p>
              </div>
            </div>
            <div class="mt-3 border rounded p-3 bg-white text-sm">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b font-bold">
                    <th class="text-left p-1">#</th>
                    <th class="text-left p-1">{gettext("Description")}</th>
                    <th class="text-right p-1">{gettext("Qty")}</th>
                    <th class="text-left p-1">{gettext("Unit")}</th>
                    <th class="text-right p-1">{gettext("Unit Price")}</th>
                    <th class="text-right p-1">{gettext("Discount")}</th>
                    <th class="text-right p-1">{gettext("Amount")}</th>
                    <th class="text-right p-1">{gettext("Tax%")}</th>
                    <th class="text-right p-1">{gettext("Tax")}</th>
                    <th class="text-left p-1">{gettext("Tax Type")}</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for {line, idx} <- Enum.with_index(parsed.invoice_lines, 1) do %>
                    <tr class="border-b">
                      <td class="p-1">{idx}</td>
                      <td class="p-1">{line.descriptions}</td>
                      <td class="text-right p-1">
                        {:erlang.float_to_binary(line.quantity / 1, decimals: 2)}
                      </td>
                      <td class="p-1">{line.unit}</td>
                      <td class="text-right p-1">
                        {:erlang.float_to_binary(line.unit_price / 1, decimals: 2)}
                      </td>
                      <td class="text-right p-1">
                        {:erlang.float_to_binary(line.discount / 1, decimals: 2)}
                      </td>
                      <td class="text-right p-1">
                        {:erlang.float_to_binary(
                          (line.quantity * line.unit_price - line.discount) / 1,
                          decimals: 2
                        )}
                      </td>
                      <td class="text-right p-1">
                        {:erlang.float_to_binary(line.tax_rate / 1, decimals: 2)}
                      </td>
                      <td class="text-right p-1">
                        {:erlang.float_to_binary(
                          Float.round(
                            (line.quantity * line.unit_price - line.discount) * line.tax_rate / 100,
                            2
                          ) / 1,
                          decimals: 2
                        )}
                      </td>
                      <td class="p-1">{line.tax_code_id_lhdn} ({line.tax_scheme})</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
              <% subtotal =
                Enum.reduce(parsed.invoice_lines, 0.0, fn line, acc ->
                  acc + (line.quantity * line.unit_price - line.discount)
                end)

              tax =
                Enum.reduce(parsed.invoice_lines, 0.0, fn line, acc ->
                  acc +
                    Float.round(
                      (line.quantity * line.unit_price - line.discount) * line.tax_rate / 100,
                      2
                    )
                end) %>
              <div class="flex justify-end gap-6 mt-2 font-bold">
                <span>
                  {gettext("Subtotal")}: {:erlang.float_to_binary(subtotal / 1, decimals: 2)}
                </span>
                <span>{gettext("Tax")}: {:erlang.float_to_binary(tax / 1, decimals: 2)}</span>
                <span>
                  {gettext("Total")}: {:erlang.float_to_binary((subtotal + tax) / 1, decimals: 2)}
                </span>
              </div>
            </div>
          <% {:error, reason} -> %>
            <div class="text-red-600 font-bold">{reason}</div>
        <% end %>
      </div>
    </div>
    """
  end
end
