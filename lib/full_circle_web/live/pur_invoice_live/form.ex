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
        :new -> if(obj, do: mount_new(obj, socket), else: mount_new(socket))
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(e_inv_preview: nil)
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
    attrs =
      %{pur_invoice_no: "...new..."}

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Purchase Invoice"))
    |> assign(matched_trans: [])
    |> assign(
      :form,
      to_form(
        Billing.make_changeset(
          PurInvoice,
          %PurInvoice{},
          attrs,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
      )
    )
  end

  defp mount_new(obj, socket) do
    obj = Jason.decode!(obj)
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    {attrs, flash} =
      case FullCircle.EInvMetas.get_full_e_invoice(obj["uuid"], com, user) do
        {:ok, body} ->
          parsed = FullCircle.EInvMetas.parse_e_invoice_document(body)

          details =
            parsed.invoice_lines
            |> Enum.with_index()
            |> Enum.map(fn {line, idx} ->
              %{
                "_persistent_id" => idx,
                "descriptions" => line.descriptions,
                "quantity" => line.quantity,
                "unit_price" => line.unit_price,
                "discount" => line.discount,
                "tax_rate" => line.tax_rate,
                "good_name" => "",
                "account_name" => "",
                "tax_code_name" => "",
                "package_name" => "",
                "package_qty" => 0,
                "unit_multiplier" => 0,
                "unit" => ""
              }
            end)

          {%{
             pur_invoice_no: "...new...",
             e_inv_internal_id: parsed.internal_id,
             e_inv_uuid: obj["uuid"],
             pur_invoice_date: parsed.issue_date,
             due_date: parsed.issue_date,
             contact_name:
               (parsed.supplier_name || "")
               |> String.replace(~r/[^a-zA-Z0-9]/, "")
               |> String.downcase(),
             pur_invoice_details: details
           }, nil}

        {:error, _reason} ->
          {%{
             pur_invoice_no: "...new...",
             e_inv_internal_id: obj["internalId"],
             e_inv_uuid: obj["uuid"],
             pur_invoice_date: obj["dateTimeIssued"],
             due_date: obj["dateTimeIssued"],
             contact_name:
               obj["supplierName"]
               |> String.replace(~r/[^a-zA-Z0-9]/, "")
               |> String.downcase()
           }, gettext("Could not fetch e-invoice details. Using summary data only.")}
      end

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Purchase Invoice"))
    |> assign(matched_trans: [])
    |> then(fn s -> if flash, do: put_flash(s, :warning, flash), else: s end)
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

  defp mount_edit(socket, id) do
    object =
      Billing.get_pur_invoice!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(matched_trans: Billing.get_matcher_by("PurInvoice", id))
    |> assign(page_title: gettext("Edit Purchase Invoice") <> " " <> object.pur_invoice_no)
    |> assign(
      :form,
      to_form(Billing.make_changeset(PurInvoice, object, %{}, socket.assigns.current_company, socket.assigns.current_user))
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

  defp save(socket, :new, params) do
    case Billing.create_pur_invoice(
           params |> Map.merge(%{"pur_invoice_no" => "...new..."}),
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_pur_invoice: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/PurInvoice/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Purchase Invoice created successfully.")}")}

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
    case Billing.update_pur_invoice(
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
         |> put_flash(:info, "#{gettext("Purchase Invoice updated successfully.")}")}

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

  defp validate(params, socket) do
    changeset =
      Billing.make_changeset(
        PurInvoice,
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
    <div class="w-11/12 mx-auto border rounded-lg border-pink-500 bg-pink-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.error_box changeset={@form.source} />
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <.input type="hidden" field={@form[:pur_invoice_no]} />
        <input type="hidden" id="live_action" value={@live_action} />
        <div class="flex flex-row flex-nowrap">
          <div class="w-1/4 grow shrink">
            <.input type="hidden" field={@form[:contact_id]} />
            <.input
              field={@form[:contact_name]}
              label={gettext("Supplier")}
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
            :if={@live_action == :new and !is_nil(@form[:e_inv_uuid].value) and is_nil(@e_inv_preview)}
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

      <div :if={@live_action == :new and @e_inv_preview} class="mt-4 border rounded-lg border-blue-500 bg-blue-50 p-4">
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
                      <td class="text-right p-1">{:erlang.float_to_binary(line.quantity / 1, decimals: 2)}</td>
                      <td class="p-1">{line.unit}</td>
                      <td class="text-right p-1">{:erlang.float_to_binary(line.unit_price / 1, decimals: 2)}</td>
                      <td class="text-right p-1">{:erlang.float_to_binary(line.discount / 1, decimals: 2)}</td>
                      <td class="text-right p-1">{:erlang.float_to_binary((line.quantity * line.unit_price - line.discount) / 1, decimals: 2)}</td>
                      <td class="text-right p-1">{:erlang.float_to_binary(line.tax_rate / 1, decimals: 2)}</td>
                      <td class="text-right p-1">{:erlang.float_to_binary(Float.round((line.quantity * line.unit_price - line.discount) * line.tax_rate / 100, 2) / 1, decimals: 2)}</td>
                      <td class="p-1">{line.tax_code_id_lhdn} ({line.tax_scheme})</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
              <%
                subtotal = Enum.reduce(parsed.invoice_lines, 0.0, fn line, acc ->
                  acc + (line.quantity * line.unit_price - line.discount)
                end)
                tax = Enum.reduce(parsed.invoice_lines, 0.0, fn line, acc ->
                  acc + Float.round((line.quantity * line.unit_price - line.discount) * line.tax_rate / 100, 2)
                end)
              %>
              <div class="flex justify-end gap-6 mt-2 font-bold">
                <span>{gettext("Subtotal")}: {:erlang.float_to_binary(subtotal / 1, decimals: 2)}</span>
                <span>{gettext("Tax")}: {:erlang.float_to_binary(tax / 1, decimals: 2)}</span>
                <span>{gettext("Total")}: {:erlang.float_to_binary((subtotal + tax) / 1, decimals: 2)}</span>
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
