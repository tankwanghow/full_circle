defmodule FullCircleWeb.PaymentLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{Accounting, BillPay}
  alias FullCircle.BillPay.{Payment}
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["payment_id"]
    to = Timex.today()
    from = Timex.shift(to, months: -1)

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(query: %{from: from, to: to})
     |> assign(query_match_trans: [])
     |> assign(details_got_error: false)
     |> assign(matchers_got_error: false)
     |> assign(
       settings:
         FullCircle.Sys.load_settings(
           "Payment",
           socket.assigns.current_company,
           socket.assigns.current_user
         )
     )}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Payment"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Payment,
          %Payment{},
          %{payment_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      BillPay.get_payment!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      StdInterface.changeset(Payment, object, %{}, socket.assigns.current_company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Payment") <> " " <> object.payment_no)
    |> assign(:form, to_form(cs))
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:payment_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> Payment.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :payment_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> Payment.compute_balance()

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
        doc_type: "Payment",
        all_matched_amount: match_tran.all_matched_amount,
        balance: 0.00,
        match_amount: Decimal.negate(match_tran.balance) |> Decimal.round(2)
      })

    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:transaction_matchers, match_tran)
      |> Map.put(:action, socket.assigns.live_action)
      |> Payment.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_match_tran", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :transaction_matchers)
      |> Map.put(:action, socket.assigns.live_action)
      |> Payment.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["payment", "contact_name"], "payment" => params},
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
        %{"_target" => ["payment", "funds_account_name"], "payment" => params},
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
        %{"_target" => ["payment", "payment_details", id, "good_name"], "payment" => params},
        socket
      ) do
    detail = params["payment_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("payment_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["payment", "payment_details", id, "package_name"], "payment" => params},
        socket
      ) do
    detail = params["payment_details"][id]
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
      |> FullCircleWeb.Helpers.merge_detail("payment_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["payment", "payment_details", id, "account_name"], "payment" => params},
        socket
      ) do
    detail = params["payment_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("payment_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["payment", "payment_details", id, "tax_code_name"], "payment" => params},
        socket
      ) do
    detail = params["payment_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("payment_details", id, detail)

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
  def handle_event("validate", %{"payment" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"payment" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Payment,
           "payment",
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
    case BillPay.create_payment(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_payment: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Payment/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Payment created successfully."))}

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
    params = params |> FullCircleWeb.Helpers.put_into_matchers("doc_date", params["payment_date"])

    case BillPay.update_payment(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_payment: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Payment/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Payment updated successfully."))}

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
    params = params |> FullCircleWeb.Helpers.put_into_matchers("doc_date", params["payment_date"])

    changeset =
      if socket.assigns.current_role == :admin do
        StdInterface.changeset(
          Payment,
          socket.assigns.form.data,
          params,
          socket.assigns.current_company
        )
      else
        StdInterface.changeset(
          Payment,
          socket.assigns.form.data,
          params,
          socket.assigns.current_company,
          :admin_changeset
        )
      end
      |> Map.put(:action, socket.assigns.live_action)

    socket =
      assign(socket, form: to_form(changeset))
      |> FullCircleWeb.Helpers.assign_got_error(:details_got_error, changeset, :payment_details)
      |> FullCircleWeb.Helpers.assign_got_error(
        :matchers_got_error,
        changeset,
        :transaction_matchers
      )

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto border rounded-lg border-pink-500 bg-pink-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <div class="float-right mt-8 mr-4">
          <% {url, qrcode} = FullCircle.Helpers.e_invoice_validation_url_qrcode(@form.source.data) %>
          <.link target="_blank" href={url}>
            {qrcode |> raw}
          </.link>
        </div>
        <.input type="hidden" field={@form[:payment_no]} />
        <div class="flex flex-row flex-nowarp w-[92%]">
          <div class="w-5/12 grow shrink">
            <.input type="hidden" field={@form[:contact_id]} />
            <.input
              field={@form[:contact_name]}
              label={gettext("Pay To")}
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
              phx-hook="calculatorInput"
              klass="text-right"
              step="0.01"
            />
          </div>
          <div class="grow shrink w-2/12">
            <.input field={@form[:payment_date]} label={gettext("Payment Date")} type="date" />
          </div>
        </div>
        <div class="flex flex-row flex-nowrap w-[92%]">
          <div class="grow shrink w-10/12">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
          <div class="grow shrink w-2/12">
            <.input
              feedback={true}
              type="number"
              readonly
              field={@form[:payment_balance]}
              label={gettext("Payment Balance")}
              value={Ecto.Changeset.fetch_field!(@form.source, :payment_balance)}
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
            :if={is_nil(@form[:e_inv_uuid].value) and @live_action != :new}
            class="text-blue-600 hover:font-medium w-[20%] ml-5 mt-6"
          >
            <a
              id={@form[:payment_no].value}
              href="#"
              phx-hook="copyAndOpen"
              copy-text={@form[:payment_no].value}
              goto-url="https://myinvois.hasil.gov.my/newdocument"
            >
              {gettext("New E-Invoice")}
            </a>
          </div>
          <div
            :if={!is_nil(@form[:e_inv_uuid].value)}
            class="text-blue-600 hover:font-medium w-[20%] ml-5 mt-6"
          >
            <.link
              target="_blank"
              href={~w(https://myinvois.hasil.gov.my/documents/#{@form[:e_inv_uuid].value})}
            >
              Open E-Invoice
            </.link>
          </div>
        </div>

        <div class="flex flex-row gap-2 flex-nowrap w-2/3 mx-auto text-center mt-5">
          <div
            id="match-trans-tab"
            phx-click={
              JS.show(to: "#match-trans")
              |> JS.add_class("active")
              |> JS.hide(to: "#payment-details")
              |> JS.remove_class("active", to: "#payment-details-tab")
              |> JS.show(to: "#query-match-trans")
            }
            class="active basis-1/2 tab"
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
            id="payment-details-tab"
            phx-click={
              JS.hide(to: "#match-trans")
              |> JS.hide(to: "#query-match-trans")
              |> JS.remove_class("active", to: "#match-trans-tab")
              |> JS.show(to: "#payment-details")
              |> JS.add_class("active")
            }
            class="basis-1/2 tab"
          >
            {gettext("Details")} =
            <span
              :if={!Decimal.eq?(Ecto.Changeset.fetch_field!(@form.source, :payment_detail_amount), 0)}
              class="font-normal text-rose-700"
            >
              {Ecto.Changeset.fetch_field!(@form.source, :payment_detail_amount)
              |> Number.Delimit.number_to_delimited()}
            </span>
            <span class="text-rose-500">
              <.icon :if={@details_got_error} name="hero-exclamation-triangle-mini" class="h-5 w-5" />
            </span>
          </div>
        </div>

        <.live_component
          module={FullCircleWeb.InvoiceLive.DetailComponent}
          id="payment-details"
          klass="hidden text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
          settings={@settings}
          doc_name="Payment"
          detail_name={:payment_details}
          form={@form}
          taxcodetype="saltaxcode"
          doc_good_amount={:payment_good_amount}
          doc_tax_amount={:payment_tax_amount}
          doc_detail_amount={:payment_detail_amount}
          current_company={@current_company}
          current_user={@current_user}
          matched_trans={[]}
        />

        <.live_component
          module={FullCircleWeb.ReceiptLive.MatcherComponent}
          id="match-trans"
          klass="text-center border bg-green-100 mt-2 p-3 rounded-lg border-green-400"
          form={@form}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="Payment"
          />
          <.print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="Payment"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="Payment"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="payments"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="Payment"
            doc_no={@form.data.payment_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>
    <.live_component
      module={FullCircleWeb.ReceiptLive.QryMatcherComponent}
      id="query-match-trans"
      klass="w-11/12 mx-auto text-center border bg-green-100 mt-2 p-3 rounded-lg border-green-400"
      query={@query}
      query_match_trans={@query_match_trans}
      form={@form}
      cannot_match_doc_type={~w(Payment)}
      doc_no_field={:payment_no}
      current_company={@current_company}
      current_user={@current_user}
    />
    """
  end
end
