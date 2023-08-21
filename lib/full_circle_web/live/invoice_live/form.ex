defmodule FullCircleWeb.InvoiceLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Billing
  alias FullCircle.Billing.{Invoice}
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
           "Invoice",
           socket.assigns.current_company,
           socket.assigns.current_user
         )
     )}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Invoice"))
    |> assign(matched_trans: [])
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Invoice,
          %Invoice{},
          %{invoice_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
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
      to_form(StdInterface.changeset(Invoice, object, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    socket = socket |> FullCircleWeb.Helpers.add_line(:invoice_details)
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    socket =
      socket
      |> FullCircleWeb.Helpers.delete_line(
        index,
        :invoice_details,
        &Invoice.compute_fields/1
      )

    {:noreply, socket}
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
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(cancel_url: uri)}
  end

  defp save(socket, :new, params) do
    case Billing.create_invoice(
           params,
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
      StdInterface.changeset(
        Invoice,
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
    <div class="w-11/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <%= Phoenix.HTML.Form.hidden_input(@form, :invoice_no) %>
        <div class="flex flex-row flex-nowarp">
          <div class="w-1/2 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :contact_id) %>
            <.input
              field={@form[:contact_name]}
              label={gettext("Customer")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:invoice_date]} label={gettext("Invoice Date")} type="date" />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:due_date]} label={gettext("Due Date")} type="date" />
          </div>
        </div>

        <div class="flex flex-row flex-nowrap gap-2">
          <div class="grow shrink">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:tags]}
              label={gettext("Tags")}
              phx-hook="tributeTagText"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/tags?klass=FullCircle.Billing.Invoice&tag="}
            />
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
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <.link
            :if={Enum.any?(@form.source.changes) and @live_action != :new}
            navigate=""
            class="orange_button"
          >
            <%= gettext("Cancel") %>
          </.link>
          <a onclick="history.back();" class="blue_button"><%= gettext("Back") %></a>
          <.link
            :if={@live_action == :edit}
            navigate={~p"/companies/#{@current_company.id}/Invoice/new"}
            class="blue_button"
          >
            <%= gettext("New") %>
          </.link>
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Invoice"
            doc_id={@id}
            class="gray_button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Invoice"
            doc_id={@id}
            class="gray_button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
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
    </div>
    """
  end
end
