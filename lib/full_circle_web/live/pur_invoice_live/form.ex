defmodule FullCircleWeb.PurInvoiceLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Billing
  alias FullCircle.Billing.{PurInvoice}
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["invoice_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
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
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Purchase Invoice"))
    |> assign(matched_trans: [])
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          PurInvoice,
          %PurInvoice{},
          %{pur_invoice_no: "...new..."},
          socket.assigns.current_company
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
      to_form(StdInterface.changeset(PurInvoice, object, %{}, socket.assigns.current_company))
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
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "contact_name",
        "contact_id",
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

  defp save(socket, :new, params) do
    case Billing.create_pur_invoice(
           params,
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

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        PurInvoice,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto border rounded-lg border-pink-500 bg-pink-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <%= Phoenix.HTML.Form.hidden_input(@form, :pur_invoice_no) %>
        <div class="flex flex-row flex-nowarp">
          <div class="w-1/4 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :contact_id) %>
            <.input
              field={@form[:contact_name]}
              label={gettext("Supplier")}
              phx-hook="tributeAutoComplete"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="grow shrink">
            <.input field={@form[:supplier_invoice_no]} label={gettext("Invoice No")} />
          </div>
          <div class="grow shrink">
            <.input field={@form[:pur_invoice_date]} label={gettext("Invoice Date")} type="date" />
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
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=loader_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:loader_wages_tags]}
              label={gettext("Loader Wages Tags")}
              phx-hook="tributeTagText"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=loader_wages_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:delivery_man_tags]}
              label={gettext("Delivery Man Tags")}
              phx-hook="tributeTagText"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=delivery_man_tags&tag="}
            />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:delivery_wages_tags]}
              label={gettext("Delivery Wages Tags")}
              phx-hook="tributeTagText"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.PurInvoice&tag_field=delivery_wages_tags&tag="}
            />
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
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="pur_invoices"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="PurInvoice"
            doc_no={@form.data.pur_invoice_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
