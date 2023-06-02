defmodule FullCircleWeb.InvoiceLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Billing
  alias FullCircle.Billing.{Invoice, InvoiceDetail}
  alias FullCircle.StdInterface
  alias FullCircle.Sys

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)

    {:ok,
     socket
     |> assign(
       account_names: [],
       contact_names: [],
       tax_codes: [],
       package_names: [],
       good_names: [],
       tagurl:
         "/api/companies/#{socket.assigns.current_company.id}/tags?klass=FullCircle.Billing.Invoice",
       settings:
         FullCircle.Sys.load_settings(
           "invoices",
           socket.assigns.current_user,
           socket.assigns.current_company
         )
     )}
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    socket = socket |> FullCircleWeb.Helpers.add_lines(:invoice_details, %InvoiceDetail{})
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    socket =
      socket
      |> FullCircleWeb.Helpers.delete_lines(String.to_integer(index), :invoice_details)
      |> update(:form, fn %{source: changeset} ->
        changeset |> Invoice.compute_fields() |> to_form()
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["settings", id, "value"], "settings" => new_settings},
        socket
      ) do
    settings = socket.assigns.settings

    setting = Enum.find(settings, fn x -> x.id == String.to_integer(id) end)

    %{"value" => value} = Map.get(new_settings, id)

    setting = FullCircle.Sys.update_setting(setting, value)

    settings =
      Enum.reject(settings, fn x -> x.id == String.to_integer(id) end)
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
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "contact_name",
        :contact_names,
        "contact_id",
        &FullCircle.Accounting.contact_names/3
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
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        detail,
        "good_name",
        :good_names,
        "good_id",
        &FullCircle.Product.good_names/3
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

    list =
      FullCircle.Product.package_names(
        terms,
        detail["good_id"]
      )

    pack = Enum.find(list, fn x -> x.value == terms end)
    socket = assign(socket, package_names: list)

    detail =
      Map.merge(detail, %{
        "package_id" => Util.attempt(pack, :id) || -1,
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
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        detail,
        "account_name",
        :account_names,
        "account_id",
        &FullCircle.Accounting.account_names/3
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
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        detail,
        "tax_code_name",
        :tax_codes,
        "tax_code_id",
        &FullCircle.Accounting.sale_tax_codes/3
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
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Invoice,
           "invoice",
           socket.assigns.form.data,
           socket.assigns.current_user,
           socket.assigns.current_company
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
    case Billing.create_invoice(
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, %{create_invoice: obj}} ->
        send(self(), {:created, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :edit, params) do
    case Billing.update_invoice(
           socket.assigns.form.data,
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, %{update_invoice: obj}} ->
        send(self(), {:updated, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        socket =
          socket
          |> assign(form: to_form(changeset))
          |> put_flash(
            :error,
            "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
          )

        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}

      {:sql_error, msg} ->
        send(self(), {:sql_error, msg})
        {:noreply, socket}
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
    <div>
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        phx-target={@myself}
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class=""
      >
        <%= Phoenix.HTML.Form.hidden_input(@form, :invoice_no) %>
        <div class="flex flex-row flex-nowarp">
          <div class="w-1/2 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :contact_id) %>
            <.input
              field={@form[:contact_name]}
              label={gettext("Customer")}
              list="contact_names"
              phx-debounce={500}
            />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:invoice_date]} label={gettext("Invoice Date")} type="date" />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:due_date]} label={gettext("Due Date")} type="date" />
          </div>
        </div>

        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="detail-header w-28 shrink-[3] grow-[3]"><%= gettext("Good") %></div>
          <div class="detail-header w-36 shrink-[3] grow-[3]">
            <%= gettext("Description") %>
          </div>
          <div class="detail-header w-28 shrink-[1] grow-[1]"><%= gettext("Package") %></div>
          <div class="detail-header w-20 shrink-[1] grow-[1]"><%= gettext("Pack Qty") %></div>
          <div class="detail-header w-24 shrink-[1] grow-[1]"><%= gettext("Quantity") %></div>
          <div class="detail-header w-16 shrink-0 grow-0"><%= gettext("Unit") %></div>
          <div class="detail-header w-24 shrink-[1] grow-[1]"><%= gettext("Price") %></div>
          <div class={"#{Sys.get_setting(@settings, "invoices", "goodamt-col")} detail-header w-24"}>
            <%= gettext("Good Amt") %>
          </div>
          <div class={"#{Sys.get_setting(@settings, "invoices", "discount-col")} detail-header w-24"}>
            <%= gettext("Discount") %>
          </div>
          <div class={"#{Sys.get_setting(@settings, "invoices", "account-col")} detail-header w-28"}>
            <%= gettext("Account") %>
          </div>
          <div class="detail-header w-16 shrink-[1] grow-[1]"><%= gettext("TaxCode") %></div>
          <div class={"#{Sys.get_setting(@settings, "invoices", "taxrate-col")} detail-header w-14"}>
            <%= gettext("Tax%") %>
          </div>
          <div class={"#{Sys.get_setting(@settings, "invoices", "taxamt-col")} detail-header w-20"}>
            <%= gettext("Tax Amt") %>
          </div>
          <div class="detail-header w-24 shrink-[1] grow-[1]"><%= gettext("Amount") %></div>
          <div class="w-5 mt-1 text-blue-500 grow-0 shrink-0">
            <.settings id="invoice-settings" settings={@settings} />
          </div>
        </div>

        <.inputs_for :let={dtl} field={@form[:invoice_details]}>
          <div class={"flex flex-row flex-wrap #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
            <div class="w-28 grow-[3] shrink-[3]">
              <.input field={dtl[:good_name]} list="good_names" phx-debounce={500} />
            </div>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :good_id) %>
            <div class="w-36 grow-[3] shrink-[3]"><.input field={dtl[:descriptions]} /></div>
            <div class="w-28 grow-[1] shrink-[1]">
              <.input field={dtl[:package_name]} list="package_names" phx-debounce={500} />
            </div>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :unit_multiplier) %>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :package_id) %>
            <div class="w-20 grow-[1] shrink-[1]">
              <.input type="number" field={dtl[:package_qty]} />
            </div>
            <div class="w-24 grow-[1] shrink-[1]">
              <.input type="number" field={dtl[:quantity]} step="0.0001" />
            </div>
            <div class="w-16 grow-0 shrink-0">
              <.input field={dtl[:unit]} readonly tabindex="-1" />
            </div>
            <div class="w-24 grow-[1] shrink-[1]">
              <.input type="number" field={dtl[:unit_price]} step="0.0001" />
            </div>
            <div class={"#{Sys.get_setting(@settings, "invoices", "goodamt-col")} w-24"}>
              <.input type="number" field={dtl[:good_amount]} readonly tabindex="-1" />
            </div>
            <div class={"#{Sys.get_setting(@settings, "invoices", "discount-col")} w-24"}>
              <.input type="number" field={dtl[:discount]} step="0.01" />
            </div>
            <div class={"#{Sys.get_setting(@settings, "invoices", "account-col")} w-28"}>
              <.input field={dtl[:account_name]} list="account_names" phx-debounce={500} />
            </div>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :account_id) %>
            <div class="w-16 grow-[1] shrink-[1]">
              <.input field={dtl[:tax_code_name]} list="tax_codes" phx-debounce={500} />
            </div>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :tax_code_id) %>
            <div class={"#{Sys.get_setting(@settings, "invoices", "taxrate-col")} w-14"}>
              <.input type="number" field={dtl[:tax_rate]} readonly step="0.0001" />
            </div>
            <div class={"#{Sys.get_setting(@settings, "invoices", "taxamt-col")} w-20"}>
              <.input type="number" field={dtl[:tax_amount]} readonly tabindex="-1" />
            </div>
            <div class="w-24 grow-[1] shrink-[1]">
              <.input type="number" field={dtl[:amount]} readonly tabindex="-1" />
            </div>
            <div class="w-5 mt-2.5 text-rose-500 grow-0 shrink-0">
              <.link
                phx-click={:delete_detail}
                phx-value-index={dtl.index}
                phx-target={@myself}
                tabindex="-1"
              >
                <.icon name="hero-trash-solid" class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
            </div>
          </div>
        </.inputs_for>

        <div class="flex flex-row flex-wrap font-medium tracking-tighter">
          <div class="w-28 shrink-[3] grow-[3] text-orange-500 mt-2">
            <.link phx-click={:add_detail} phx-target={@myself}>
              <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Detail") %>
            </.link>
          </div>
          <div class="w-36 shrink-[3] grow-[3]" />

          <div class="w-28 shrink-[1] grow-[1]" />
          <div class="w-20 shrink-[1] grow-[1]" />
          <div class="w-24 shrink-[1] grow-[1]" />
          <div class="w-16 shrink-0 grow-0" />
          <div class="w-24 shrink-[1] grow-[1]" />
          <div class={"#{Sys.get_setting(@settings, "invoices", "goodamt-col")} w-24"}>
            <.input type="number" field={@form[:invoice_good_amount]} readonly tabindex="-1" />
          </div>
          <div class={"#{Sys.get_setting(@settings, "invoices", "discount-col")} w-24"} />
          <div class={"#{Sys.get_setting(@settings, "invoices", "account-col")} w-28"} />
          <div class="w-16 shrink-[1] grow-[1]" />
          <div class={"#{Sys.get_setting(@settings, "invoices", "taxrate-col")} w-14"} />
          <div class={"#{Sys.get_setting(@settings, "invoices", "taxamt-col")} w-20"}>
            <.input type="number" field={@form[:invoice_tax_amount]} readonly tabindex="-1" />
          </div>
          <div class="w-24 shrink-[1] grow-[1]">
            <.input type="number" field={@form[:invoice_amount]} readonly tabindex="-1" />
          </div>
          <div class="w-5 grow-0 shrink-0" />
        </div>

        <div class="flex flex-row flex-nowrap gap-2">
          <div class="grow shrink">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />
          </div>
          <div class="grow shrink">
            <.input
              field={@form[:tags]}
              label={gettext("Tags")}
              type="textarea"
              phx-hook="tributeTextArea"
              tag-url={@tagurl}
            />
          </div>
        </div>

        <%= datalist_with_ids(@account_names, "account_names") %>
        <%= datalist_with_ids(@tax_codes, "tax_codes") %>
        <%= datalist_with_ids(@contact_names, "contact_names") %>
        <%= datalist_with_ids(@good_names, "good_names") %>
        <%= datalist_with_ids(@package_names, "package_names") %>
        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Invoice Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.remove_attribute("class", to: "#phx-feedback-for-contact_name")
                |> JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.link phx-click={JS.exec("phx-remove", to: "#object-crud-modal")} class={button_css()}>
            <%= gettext("Back") %>
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
