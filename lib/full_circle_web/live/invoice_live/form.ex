defmodule FullCircleWeb.InvoiceLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Billing
  alias FullCircle.Billing.{Invoice}

  @impl true
  def mount(params, _session, socket) do
    id = params["invoice_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket, params)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(e_inv_preview: nil)
     |> assign(
       settings:
         FullCircle.Sys.load_settings(
           "Invoice",
           socket.assigns.current_company,
           socket.assigns.current_user
         )
     )}
  end

  defp mount_new(socket, params) do
    attrs =
      if params["egg"] do
        egg_quantities = parse_egg_quantities(params["egg"])
        details = Billing.build_invoice_details_from_egg_order(
          egg_quantities,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
        %{
          invoice_no: "...new...",
          contact_name: params["contact_name"],
          contact_id: params["contact_id"],
          invoice_date: params["date"],
          load_date: params["date"],
          invoice_details: details
        }
      else
        %{invoice_no: "...new..."}
      end

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Invoice"))
    |> assign(matched_trans: [])
    |> assign(
      :form,
      to_form(
        Billing.make_changeset(
          Invoice,
          %Invoice{},
          attrs,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
      )
    )
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
      Billing.get_invoice!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Invoice") <> " " <> object.invoice_no)
    |> assign(matched_trans: Billing.get_matcher_by("Invoice", id))
    |> assign(
      :form,
      to_form(Billing.make_changeset(Invoice, object, %{}, socket.assigns.current_company, socket.assigns.current_user))
    )
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:invoice_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> Invoice.compute_fields()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :invoice_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> Invoice.compute_fields()

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
        %{"_target" => ["invoice", "contact_name"], "invoice" => params},
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
        %{"_target" => ["invoice", "invoice_details", id, "good_name"], "invoice" => params},
        socket
      ) do
    detail = params["invoice_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("invoice_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["invoice", "invoice_details", id, "package_name"], "invoice" => params},
        socket
      ) do
    detail = params["invoice_details"][id]
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
      |> FullCircleWeb.Helpers.merge_detail("invoice_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["invoice", "invoice_details", id, "account_name"], "invoice" => params},
        socket
      ) do
    detail = params["invoice_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("invoice_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["invoice", "invoice_details", id, "tax_code_name"], "invoice" => params},
        socket
      ) do
    detail = params["invoice_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("invoice_details", id, detail)

    validate(params, socket)
  end

  def handle_event("validate", %{"invoice" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"invoice" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("preview_e_inv", _, socket) do
    preview =
      FullCircle.EInvMetas.preview_e_invoice(
        socket.assigns.id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply, socket |> assign(e_inv_preview: preview)}
  end

  @impl true
  def handle_event("update_preview", %{"preview" => params}, socket) do
    case socket.assigns.e_inv_preview do
      {:ok, preview} ->
        supplier =
          preview.supplier
          |> Map.merge(%{
            tin: params["supplier_tin"],
            brn: params["supplier_brn"],
            sst: params["supplier_sst"],
            msic: params["supplier_msic"],
            tel: params["supplier_tel"],
            email: params["supplier_email"],
            address: params["supplier_address"],
            city: params["supplier_city"],
            zipcode: params["supplier_zipcode"],
            state: params["supplier_state"]
          })

        customer =
          preview.customer
          |> Map.merge(%{
            tin: params["customer_tin"],
            brn: params["customer_brn"],
            sst: params["customer_sst"],
            tel: params["customer_tel"],
            email: params["customer_email"],
            address: params["customer_address"],
            city: params["customer_city"],
            zipcode: params["customer_zipcode"],
            state: params["customer_state"]
          })

        updated =
          preview
          |> Map.put(:supplier, supplier)
          |> Map.put(:customer, customer)
          |> Map.put(:warnings, FullCircle.EInvMetas.validate_preview(supplier, customer))

        {:noreply, socket |> assign(e_inv_preview: {:ok, updated})}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_preview", _, socket) do
    {:noreply, socket |> assign(e_inv_preview: nil)}
  end

  @impl true
  def handle_event("submit_e_inv", _, socket) do
    {:ok, preview} = socket.assigns.e_inv_preview

    case FullCircle.EInvMetas.submit_e_invoice(
           socket.assigns.id,
           preview,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, uuid} ->
        {:noreply,
         socket
         |> assign(e_inv_preview: nil)
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Invoice/#{socket.assigns.id}/edit"
         )
         |> put_flash(:info, "#{gettext("E-Invoice submitted successfully.")} UUID: #{uuid}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(e_inv_preview: nil)
         |> put_flash(:error, "#{gettext("E-Invoice submission failed:")} #{reason}")}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(cancel_url: uri)}
  end

  defp save(socket, :new, params) do
    case Billing.create_invoice(
           params |> Map.merge(%{"invoice_no" => "...new..."}),
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_invoice: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Invoice/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Invoice created successfully.")}")}

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
    case Billing.update_invoice(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_invoice: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Invoice/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Invoice updated successfully.")}")}

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

  defp validate(params, socket) do
    changeset =
      Billing.make_changeset(
        Invoice,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.error_box changeset={@form.source} />
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <.input type="hidden" field={@form[:invoice_no]} />
        <div class="flex flex-row flex-nowrap">
          <div class="w-1/4 grow shrink">
            <.input type="hidden" field={@form[:contact_id]} />
            <.input
              field={@form[:contact_name]}
              label={gettext("Customer")}
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
          <div class="grow shrink">
            <.input field={@form[:invoice_date]} label={gettext("Invoice Date")} type="date" />
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
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.Invoice&tag_field=loader_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:loader_wages_tags]}
              label={gettext("Loader Wages Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.Invoice&tag_field=loader_wages_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:delivery_man_tags]}
              label={gettext("Delivery Man Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.Invoice&tag_field=delivery_man_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:delivery_wages_tags]}
              label={gettext("Delivery Wages Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.Invoice&tag_field=delivery_wages_tags&tag="}
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
            :if={is_nil(@form[:e_inv_uuid].value) and @live_action == :edit}
            class="ml-5 mt-5"
          >
            <.link phx-click="preview_e_inv" class="blue button">
              {gettext("Preview E-Invoice")}
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
          <div class="shrink-0 ml-2 mt-1">
            <% {url, qrcode} =
              FullCircle.Helpers.e_invoice_validation_url_qrcode(@form.source.data, 1) %>
            <.link target="_blank" href={url}>
              {qrcode |> raw}
            </.link>
          </div>
        </div>

        <.live_component
          module={FullCircleWeb.InvoiceLive.DetailComponent}
          id="invoice_details"
          klass=""
          settings={@settings}
          doc_name="Invoice"
          detail_name={:invoice_details}
          form={@form}
          taxcodetype="saltaxcode"
          doc_good_amount={:invoice_good_amount}
          doc_tax_amount={:invoice_tax_amount}
          doc_detail_amount={:invoice_amount}
          matched_trans={@matched_trans}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex flex-row justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="Invoice"
          />
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Invoice"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Invoice"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="invoices"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="Invoice"
            doc_no={@form.data.invoice_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>

      <div :if={@e_inv_preview} class="mt-4 border rounded-lg border-blue-500 bg-blue-50 p-4">
        <div class="flex justify-between items-center mb-3">
          <p class="text-xl font-medium">{gettext("E-Invoice Preview")}</p>
          <.link phx-click="close_preview" class="orange button text-sm">
            {gettext("Close")}
          </.link>
        </div>
        <%= case @e_inv_preview do %>
          <% {:ok, preview} -> %>
            <div :if={preview.warnings != []} class="mb-3 p-3 bg-red-100 border border-red-400 rounded text-sm text-red-700">
              <p class="font-bold mb-1">{gettext("Validation Warnings (fix before submitting):")}</p>
              <ul class="list-disc ml-4">
                <li :for={w <- preview.warnings}>{w}</li>
              </ul>
            </div>
            <form phx-change="update_preview" id="preview-form">
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div class="border rounded p-3 bg-white">
                  <p class="font-bold mb-2">{gettext("Supplier")}</p>
                  <p class="font-medium">{preview.supplier.name}</p>
                  <div class="grid grid-cols-2 gap-1 mt-1">
                    <label class="text-xs text-gray-500">TIN</label>
                    <input type="text" name="preview[supplier_tin]" value={preview.supplier.tin} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">BRN</label>
                    <input type="text" name="preview[supplier_brn]" value={preview.supplier.brn} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">SST</label>
                    <input type="text" name="preview[supplier_sst]" value={preview.supplier.sst} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">MSIC</label>
                    <input type="text" name="preview[supplier_msic]" value={preview.supplier.msic} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">Tel</label>
                    <input type="text" name="preview[supplier_tel]" value={preview.supplier.tel} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">Email</label>
                    <input type="text" name="preview[supplier_email]" value={preview.supplier.email} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("Address")}</label>
                    <input type="text" name="preview[supplier_address]" value={preview.supplier.address} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("City")}</label>
                    <input type="text" name="preview[supplier_city]" value={preview.supplier.city} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("Postal Code")}</label>
                    <input type="text" name="preview[supplier_zipcode]" value={preview.supplier.zipcode} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("State")}</label>
                    <input type="text" name="preview[supplier_state]" value={preview.supplier.state} class="text-sm border rounded px-1" />
                  </div>
                </div>
                <div class="border rounded p-3 bg-white">
                  <p class="font-bold mb-2">{gettext("Customer")}</p>
                  <p class="font-medium">{preview.customer.name}</p>
                  <div class="grid grid-cols-2 gap-1 mt-1">
                    <label class="text-xs text-gray-500">TIN</label>
                    <input type="text" name="preview[customer_tin]" value={preview.customer.tin} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">BRN</label>
                    <input type="text" name="preview[customer_brn]" value={preview.customer.brn} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">SST</label>
                    <input type="text" name="preview[customer_sst]" value={preview.customer.sst} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">Tel</label>
                    <input type="text" name="preview[customer_tel]" value={preview.customer.tel} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">Email</label>
                    <input type="text" name="preview[customer_email]" value={preview.customer.email} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("Address")}</label>
                    <input type="text" name="preview[customer_address]" value={preview.customer.address} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("City")}</label>
                    <input type="text" name="preview[customer_city]" value={preview.customer.city} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("Postal Code")}</label>
                    <input type="text" name="preview[customer_zipcode]" value={preview.customer.zipcode} class="text-sm border rounded px-1" />
                    <label class="text-xs text-gray-500">{gettext("State")}</label>
                    <input type="text" name="preview[customer_state]" value={preview.customer.state} class="text-sm border rounded px-1" />
                  </div>
                </div>
              </div>
            </form>
            <div class="mt-3 border rounded p-3 bg-white text-sm">
              <div class="flex gap-4 mb-2">
                <span><span class="font-bold">{gettext("Invoice No")}:</span> {preview.invoice_no}</span>
                <span><span class="font-bold">{gettext("Date")}:</span> {preview.invoice_date}</span>
                <span><span class="font-bold">{gettext("Currency")}:</span> MYR</span>
                <span><span class="font-bold">{gettext("Type")}:</span> Invoice (01)</span>
              </div>
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
                  <%= for line <- preview.lines do %>
                    <tr class="border-b">
                      <td class="p-1">{line.idx}</td>
                      <td class="p-1">{line.description}</td>
                      <td class="text-right p-1">{line.quantity}</td>
                      <td class="p-1">{line.unit} → {line.lhdn_unit}</td>
                      <td class="text-right p-1">{line.unit_price}</td>
                      <td class="text-right p-1">{line.discount}</td>
                      <td class="text-right p-1">{line.good_amount}</td>
                      <td class="text-right p-1">{line.tax_rate}</td>
                      <td class="text-right p-1">{line.tax_amount}</td>
                      <td class="p-1">{line.tax_type}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
              <div class="flex justify-end gap-6 mt-2 font-bold">
                <span>{gettext("Subtotal")}: {preview.total_excl}</span>
                <span>{gettext("Tax")}: {preview.total_tax}</span>
                <span>{gettext("Total")}: {preview.total_incl}</span>
              </div>
            </div>
            <div class="mt-3 flex justify-center gap-2">
              <.link
                phx-click="submit_e_inv"
                data-confirm={gettext("Confirm submit to LHDN?")}
                class="green button"
              >
                {gettext("Submit to LHDN")}
              </.link>
              <.link phx-click="close_preview" class="orange button">
                {gettext("Cancel")}
              </.link>
            </div>
          <% {:error, reason} -> %>
            <div class="text-red-600 font-bold">{reason}</div>
        <% end %>
      </div>
    </div>
    """
  end
end
