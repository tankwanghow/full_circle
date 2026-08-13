defmodule FullCircleWeb.ReceiptLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{Accounting, ReceiveFund}
  alias FullCircle.ReceiveFund.{Receipt}
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["receipt_id"]
    to = Timex.today()
    from = Timex.shift(to, months: -1)

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket, params)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(query: %{from: from, to: to})
     |> assign(query_match_trans: [])
     |> assign(cheques_got_error: false)
     |> assign(details_got_error: false)
     |> assign(matchers_got_error: false)
     |> assign(contact_advances: [])
     |> assign_new(:e_inv_document, fn -> nil end)
     |> assign_new(:e_inv_supplier_ids, fn -> nil end)
     |> assign(
       settings:
         FullCircle.Sys.load_settings(
           "Receipt",
           socket.assigns.current_company,
           socket.assigns.current_user
         )
     )}
  end

  defp mount_new(socket, %{"obj" => obj}) when is_binary(obj) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    seed =
      Jason.decode!(obj)
      |> FullCircle.EInvMetas.Prefill.build(com, user, :receipt_details, side: :sales)

    attrs =
      Map.merge(seed.attrs, %{
        receipt_no: "...new...",
        receipt_date: seed.issue_date,
        load_date: seed.issue_date,
        # LHDN payable is what this receipt settles — same anchor as Payment.
        funds_amount: seed.payable
      })

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Receipt"))
    |> assign_egg_link(%{}, :sales)
    |> assign(e_inv_supplier_ids: seed.contact_ids)
    |> assign(e_inv_document: seed.preview)
    |> then(fn s ->
      case Enum.reject(seed.warnings, &is_nil/1) do
        [] -> s
        msgs -> put_flash(s, :warn, Enum.join(msgs, " "))
      end
    end)
    |> assign(
      :form,
      to_form(ReceiveFund.make_changeset(Receipt, %Receipt{}, attrs, com, user))
    )
  end

  defp mount_new(socket, params) do
    attrs =
      if params["egg"] do
        egg_quantities = parse_egg_quantities(params["egg"])

        details =
          FullCircle.Billing.build_invoice_details_from_egg_order(
            egg_quantities,
            socket.assigns.current_company,
            socket.assigns.current_user
          )

        %{
          receipt_no: "...new...",
          contact_name: params["contact_name"],
          contact_id: blank_id(params["contact_id"]),
          receipt_date: params["date"],
          load_date: params["date"],
          receipt_details: details
        }
      else
        %{receipt_no: "...new..."}
      end

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Receipt"))
    |> assign_egg_link(params, :sales)
    |> assign(
      :form,
      to_form(
        ReceiveFund.make_changeset(
          Receipt,
          %Receipt{},
          attrs,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
      )
    )
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

  defp maybe_learn_e_inv_contact_ids(socket, obj) do
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

  defp maybe_attach_egg_planned(socket, obj, params) do
    if socket.assigns[:egg_detail_id] || socket.assigns[:egg_load_date] do
      load_date =
        Map.get(obj, :load_date) || Map.get(obj, :receipt_date) || socket.assigns[:egg_load_date]

      FullCircle.EggStock.attach_contact_from_document(
        socket.assigns.current_company,
        socket.assigns.current_user,
        %{
          detail_id: socket.assigns[:egg_detail_id],
          load_date: parse_date(load_date),
          side: socket.assigns[:egg_side] || :sales,
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

  defp mount_edit(socket, id) do
    object =
      ReceiveFund.get_receipt!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      ReceiveFund.make_changeset(
        Receipt,
        object,
        %{},
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Receipt") <> " " <> object.receipt_no)
    |> assign(:form, to_form(cs))
  end

  @impl true
  def handle_event("close_e_inv_document", _, socket) do
    {:noreply, socket |> assign(e_inv_document: nil)}
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:receipt_details)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :receipt_details)
      |> Receipt.compute_balance()
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("add_cheque", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:received_cheques)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_cheque", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :received_cheques)
      |> Receipt.compute_balance()
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("get_trans", %{"query" => %{"from" => from, "to" => to}}, socket) do
    ctid = Ecto.Changeset.fetch_field!(socket.assigns.form.source, :contact_id)

    trans =
      Accounting.query_transactions_for_matching(
        ctid,
        from,
        to,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply, socket |> assign(query: %{from: from, to: to}) |> assign(query_match_trans: trans)}
  end

  @impl true
  def handle_event("add_match_tran", %{"trans-id" => id}, socket) do
    match_tran =
      socket.assigns.query_match_trans
      |> Enum.find(fn x -> x.transaction_id == id end)

    match_tran =
      match_tran
      |> Map.merge(%{
        account_id: match_tran.account_id,
        doc_type: "Receipt",
        all_matched_amount: match_tran.all_matched_amount,
        balance: 0.00,
        match_amount: Decimal.negate(match_tran.balance) |> Decimal.round(2)
      })

    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:transaction_matchers, match_tran)
      |> Receipt.compute_balance()
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_match_tran", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :transaction_matchers)
      |> Receipt.compute_balance()
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "contact_name"], "receipt" => params},
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

    socket = check_contact_advance_balance(params, socket)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "funds_account_name"], "receipt" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "funds_account_name",
        "funds_account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "good_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]

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
        "account_name" => Util.attempt(good, :sales_account_name),
        "account_id" => Util.attempt(good, :sales_account_id),
        "tax_code_name" => Util.attempt(good, :sales_tax_code_name),
        "tax_code_id" => Util.attempt(good, :sales_tax_code_id),
        "tax_rate" => Util.attempt(good, :sales_tax_rate),
        "package_name" => Util.attempt(good, :package_name),
        "package_id" => Util.attempt(good, :package_id),
        "unit" => Util.attempt(good, :unit),
        "unit_multiplier" => Util.attempt(good, :unit_multiplier) || 0,
        "package_qty" => 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "package_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]
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
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "account_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "tax_code_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
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
  def handle_event("validate", %{"receipt" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"receipt" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Receipt,
           "receipt",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, obj} ->
        send(self(), {:deleted, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :new, params) do
    params = params |> FullCircleWeb.Helpers.put_into_matchers("doc_date", params["receipt_date"])

    case ReceiveFund.create_receipt(
           params |> Map.merge(%{"receipt_no" => "...new..."}),
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_receipt: obj}} ->
        socket =
          socket
          |> maybe_attach_egg_planned(obj, params)
          |> maybe_learn_e_inv_contact_ids(obj)

        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Receipt/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Receipt created successfully."))}

      {:error, :period_closed} ->
        {:noreply,
         socket
         |> put_flash(
           :warn,
           gettext("Accounting period is closed on or before %{date}.",
             date: to_string(FullCircle.Sys.period_closed_through(socket.assigns.current_company))
           )
         )}

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
    params = params |> FullCircleWeb.Helpers.put_into_matchers("doc_date", params["receipt_date"])

    case ReceiveFund.update_receipt(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_receipt: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Receipt/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Receipt updated successfully."))}

      {:error, :period_closed} ->
        {:noreply,
         socket
         |> put_flash(
           :warn,
           gettext("Accounting period is closed on or before %{date}.",
             date: to_string(FullCircle.Sys.period_closed_through(socket.assigns.current_company))
           )
         )}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "This record was changed or deleted by someone else. Please reload and try again."
           )
         )}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
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

  defp validate(params, socket) do
    params = params |> FullCircleWeb.Helpers.put_into_matchers("doc_date", params["receipt_date"])

    changeset =
      ReceiveFund.make_changeset(
        Receipt,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket =
      assign(socket, form: to_form(changeset))
      |> FullCircleWeb.Helpers.assign_got_error(:cheques_got_error, changeset, :received_cheques)
      |> FullCircleWeb.Helpers.assign_got_error(:details_got_error, changeset, :receipt_details)
      |> FullCircleWeb.Helpers.assign_got_error(
        :matchers_got_error,
        changeset,
        :transaction_matchers
      )

    {:noreply, socket}
  end

  defp check_contact_advance_balance(params, socket) do
    contact_id = params["contact_id"]

    if contact_id != "" and not is_nil(contact_id) do
      advances = ReceiveFund.contact_advance_balance(contact_id, socket.assigns.current_company)
      assign(socket, :contact_advances, advances)
    else
      assign(socket, :contact_advances, [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.error_box changeset={@form.source} />
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <.input type="hidden" field={@form[:receipt_no]} />
        <div class="flex flex-row flex-nowrap">
          <div class="w-5/12 grow shrink">
            <.input type="hidden" field={@form[:contact_id]} />
            <.input
              field={@form[:contact_name]}
              label={gettext("Receive From")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="grow shrink">
            <.input field={@form[:reg_no]} label={gettext("Reg No")} readonly tabindex="-1" />
          </div>
          <div class="grow shrink">
            <.input field={@form[:tax_id]} label={gettext("Tax Id")} readonly tabindex="-1" />
          </div>
          <div class="w-5/12 grow shrink">
            <.input type="hidden" field={@form[:funds_account_id]} />
            <.input
              feedback={true}
              field={@form[:funds_account_name]}
              label={gettext("Funds Account")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
          <div class="w-2/12 grow shrink">
            <.input
              field={@form[:funds_amount]}
              label={gettext("Funds Amount")}
              step="0.01"
              phx-hook="calculatorInput"
              klass="text-right"
            />
          </div>
          <div class="grow shrink w-2/12">
            <.input field={@form[:receipt_date]} label={gettext("Receipt Date")} type="date" />
          </div>
          <div class="grow shrink w-2/12">
            <.input field={@form[:load_date]} label={gettext("Load Date")} type="date" />
          </div>
        </div>
        <div
          :if={@contact_advances != []}
          class="px-2 py-1 my-1 bg-amber-100 border border-amber-400 rounded text-amber-800 text-sm"
        >
          <span class="font-semibold">{gettext("Advance Balance")}:</span>
          <%= for adv <- @contact_advances do %>
            <.link
              navigate={"/companies/#{@current_company.id}/#{adv.doc_type}/#{adv.doc_id}/edit"}
              class="ml-2 underline text-blue-600 hover:text-blue-800"
            >
              {adv.doc_no} ({Number.Currency.number_to_currency(Decimal.abs(adv.amount))})
            </.link>
          <% end %>
        </div>
        <div class="flex flex-row flex-nowrap">
          <div class="grow shrink w-8/12">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
          <div class="grow shrink w-2/12">
            <.input
              feedback={true}
              type="number"
              readonly
              field={@form[:receipt_amount]}
              label={gettext("Receipt Amount")}
              value={Ecto.Changeset.fetch_field!(@form.source, :receipt_amount)}
              tabindex="-1"
            />
          </div>
          <div class="grow shrink w-2/12">
            <.input
              feedback={true}
              type="number"
              readonly
              field={@form[:receipt_balance]}
              label={gettext("Receipt Balance")}
              value={Ecto.Changeset.fetch_field!(@form.source, :receipt_balance)}
              tabindex="-1"
            />
          </div>
        </div>

        <div class="flex flex-row flex-nowrap mt-2">
          <div class="w-[14%]">
            <.input field={@form[:e_inv_internal_id]} label={gettext("E Invoice Internal Id")} />
          </div>
          <div class="w-[20%]">
            <.input field={@form[:e_inv_uuid]} label={gettext("E Invoice UUID")} />
          </div>
          <div
            :if={is_nil(@form[:e_inv_uuid].value) and @live_action != :new}
            class="text-blue-600 hover:font-medium w-[20%] ml-5 mt-6"
          >
            <a
              id={@form[:receipt_no].value}
              href="#"
              phx-hook="copyAndOpen"
              copy-text={@form[:receipt_no].value}
              goto-url={"#{@einv_portal}/newdocument"}
            >
              {gettext("New E-Invoice")}
            </a>
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
          <div class="shrink-0 ml-2 mt-1">
            <% {url, qrcode} =
              FullCircle.Helpers.e_invoice_validation_url_qrcode(@form.source.data, 1) %>
            <.link target="_blank" href={url}>
              {qrcode |> raw}
            </.link>
          </div>
        </div>

        <div class="flex flex-row gap-2 flex-nowrap w-2/3 mx-auto text-center mt-5">
          <div
            id="receipt-cheques-tab"
            phx-click={
              JS.show(to: "#receipt-cheques")
              |> JS.add_class("active")
              |> JS.hide(to: "#match-trans")
              |> JS.hide(to: "#query-match-trans")
              |> JS.remove_class("active", to: "#match-trans-tab")
              |> JS.hide(to: "#receipt-details")
              |> JS.remove_class("active", to: "#receipt-details-tab")
            }
            class="active basis-1/3 tab"
          >
            {gettext("Cheques")} =
            <span
              :if={!Decimal.eq?(Ecto.Changeset.fetch_field!(@form.source, :cheques_amount), 0)}
              class="font-normal text-green-700"
            >
              {Ecto.Changeset.fetch_field!(@form.source, :cheques_amount)
              |> Number.Delimit.number_to_delimited()}
            </span>
            <span class="text-rose-500">
              <.icon :if={@cheques_got_error} name="hero-exclamation-triangle-mini" class="h-5 w-5" />
            </span>
          </div>

          <div
            id="match-trans-tab"
            phx-click={
              JS.hide(to: "#receipt-cheques")
              |> JS.remove_class("active", to: "#receipt-cheques-tab")
              |> JS.show(to: "#match-trans")
              |> JS.add_class("active")
              |> JS.hide(to: "#receipt-details")
              |> JS.remove_class("active", to: "#receipt-details-tab")
              |> JS.show(to: "#query-match-trans")
            }
            class="basis-1/3 tab"
          >
            {gettext("Matchers")} =
            <span
              :if={!Decimal.eq?(Ecto.Changeset.fetch_field!(@form.source, :matched_amount), 0)}
              class="font-normal text-rose-700"
            >
              {Ecto.Changeset.fetch_field!(@form.source, :matched_amount)
              |> Decimal.new()
              |> Decimal.abs()
              |> Number.Delimit.number_to_delimited()}
            </span>
            <span class="text-rose-500">
              <.icon :if={@matchers_got_error} name="hero-exclamation-triangle-mini" class="h-5 w-5" />
            </span>
          </div>

          <div
            id="receipt-details-tab"
            phx-click={
              JS.hide(to: "#receipt-cheques")
              |> JS.remove_class("active", to: "#receipt-cheques-tab")
              |> JS.hide(to: "#match-trans")
              |> JS.hide(to: "#query-match-trans")
              |> JS.remove_class("active", to: "#match-trans-tab")
              |> JS.show(to: "#receipt-details")
              |> JS.add_class("active")
            }
            class="basis-1/3 tab"
          >
            {gettext("Details")} =
            <span
              :if={!Decimal.eq?(Ecto.Changeset.fetch_field!(@form.source, :receipt_detail_amount), 0)}
              class="font-normal text-rose-700"
            >
              {Ecto.Changeset.fetch_field!(@form.source, :receipt_detail_amount)
              |> Number.Delimit.number_to_delimited()}
            </span>
            <span class="text-rose-500">
              <.icon :if={@details_got_error} name="hero-exclamation-triangle-mini" class="h-5 w-5" />
            </span>
          </div>
        </div>

        <div
          id="receipt-cheques"
          class="text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
        >
          <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
            <div class="detail-header w-[16%]">{gettext("Bank")}</div>
            <div class="detail-header w-[16%]">{gettext("Cheque No")}</div>
            <div class="detail-header w-[16%]">{gettext("City")}</div>
            <div class="detail-header w-[17%]">{gettext("State")}</div>
            <div class="detail-header w-[16%]">{gettext("Due Date")}</div>
            <div class="detail-header w-[16%]">{gettext("Amount")}</div>
            <div class="w-[3%]">{gettext("")}</div>
          </div>

          <.inputs_for :let={dtl} field={@form[:received_cheques]}>
            <div class={"flex flex-row flex-wrap #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
              <div class="w-[16%]"><.input feedback={true} field={dtl[:bank]} /></div>
              <div class="w-[16%]"><.input field={dtl[:cheque_no]} /></div>
              <div class="w-[16%]"><.input field={dtl[:city]} /></div>
              <div class="w-[17%]"><.input field={dtl[:state]} /></div>
              <div class="w-[16%]"><.input type="date" field={dtl[:due_date]} /></div>
              <div class="w-[16%]">
                <.input type="number" step="0.01" field={dtl[:amount]} />
              </div>
              <div class="w-[3%] mt-2.5 text-rose-500">
                <.link phx-click={:delete_cheque} phx-value-index={dtl.index} tabindex="-1">
                  <.icon name="hero-trash-solid" class="h-5 w-5" />
                </.link>
                <.input type="hidden" field={dtl[:delete]} value={"#{dtl[:delete].value}"} />
              </div>
            </div>
          </.inputs_for>
          <div class="flex flex-row flex-wrap">
            <div class="w-[16%] text-orange-500 font-bold pt-2">
              <.link phx-click={:add_cheque}>
                <.icon name="hero-plus-circle" class="w-5 h-5" />{gettext("Add Cheque")}
              </.link>
            </div>
            <div class="w-[65%] pt-2 pr-2 font-semibold text-right">Cheques Total</div>
            <div class="w-[16%] font-semi bold">
              <.input
                type="number"
                readonly
                tabindex="-1"
                field={@form[:cheques_amount]}
                value={Ecto.Changeset.fetch_field!(@form.source, :cheques_amount)}
              />
            </div>
          </div>
        </div>

        <.live_component
          module={FullCircleWeb.InvoiceLive.DetailComponent}
          id="receipt-details"
          klass="hidden text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
          settings={@settings}
          doc_name="Receipt"
          detail_name={:receipt_details}
          form={@form}
          taxcodetype="saltaxcode"
          doc_good_amount={:receipt_good_amount}
          doc_tax_amount={:receipt_tax_amount}
          doc_detail_amount={:receipt_detail_amount}
          current_company={@current_company}
          current_user={@current_user}
          matched_trans={[]}
        />

        <.live_component
          module={FullCircleWeb.ReceiptLive.MatcherComponent}
          id="match-trans"
          klass="hidden text-center border bg-green-100 mt-2 p-3 rounded-lg border-green-400"
          form={@form}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="Receipt"
          />
          <.print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="Receipt"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="Receipt"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="receipts"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="Receipt"
            doc_no={@form.data.receipt_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>

      <div
        :if={@live_action == :new and @e_inv_document}
        class="mt-4 border rounded-lg border-blue-500 bg-blue-50 p-4"
      >
        <div class="flex justify-between items-center mb-3">
          <p class="text-xl font-medium">{gettext("E-Invoice Document")}</p>
          <.link phx-click="close_e_inv_document" class="orange button text-sm">
            {gettext("Close")}
          </.link>
        </div>
        <%= case @e_inv_document do %>
          <% {:ok, parsed} -> %>
            <div class="grid grid-cols-2 gap-4 text-sm">
              <div class="border rounded p-3 bg-white">
                <p class="font-bold mb-2">{gettext("Customer")}</p>
                <p class="font-medium">{parsed.customer_name}</p>
                <p>TIN: {parsed.customer_tin}</p>
                <p>BRN: {parsed.customer_brn}</p>
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
    <.live_component
      module={FullCircleWeb.ReceiptLive.QryMatcherComponent}
      id="query-match-trans"
      klass="hidden w-11/12 mx-auto text-center border bg-green-100 mt-2 p-3 rounded-lg border-green-400"
      query={@query}
      query_match_trans={@query_match_trans}
      form={@form}
      cannot_match_doc_type={~w(Receipt)}
      doc_no_field={:receipt_no}
      current_company={@current_company}
      current_user={@current_user}
    />
    """
  end
end
