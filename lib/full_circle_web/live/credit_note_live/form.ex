defmodule FullCircleWeb.CreditNoteLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{Accounting, DebCre}
  alias FullCircle.DebCre.{CreditNote}
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["note_id"]
    to = Timex.today()
    from = Timex.shift(to, months: -1)

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(details_got_error: false)
     |> assign(matchers_got_error: false)
     |> assign(query: %{from: from, to: to})
     |> assign(query_match_trans: [])}
  end

  defp mount_new(socket) do
    attrs = %{note_no: "...new..."}

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Credit Note"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          CreditNote,
          %CreditNote{},
          attrs,
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      DebCre.get_credit_note!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      StdInterface.changeset(CreditNote, object, %{}, socket.assigns.current_company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Credit Note") <> " " <> object.note_no)
    |> assign(:form, to_form(cs))
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:credit_note_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> CreditNote.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :credit_note_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> CreditNote.compute_balance()

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
        doc_type: "CreditNote",
        all_matched_amount: match_tran.all_matched_amount,
        balance: 0.00,
        match_amount: Decimal.negate(match_tran.balance) |> Decimal.round(2)
      })

    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:transaction_matchers, match_tran)
      |> Map.put(:action, socket.assigns.live_action)
      |> CreditNote.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_match_tran", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :transaction_matchers)
      |> Map.put(:action, socket.assigns.live_action)
      |> CreditNote.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["credit_note", "contact_name"], "credit_note" => params},
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
          "_target" => ["credit_note", "credit_note_details", id, "account_name"],
          "credit_note" => params
        },
        socket
      ) do
    detail = params["credit_note_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("credit_note_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["credit_note", "credit_note_details", id, "tax_code_name"],
          "credit_note" => params
        },
        socket
      ) do
    detail = params["credit_note_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("credit_note_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"credit_note" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"credit_note" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    params = params |> FullCircleWeb.Helpers.put_into_matchers("doc_date", params["note_date"])

    case DebCre.create_credit_note(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_credit_note: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/CreditNote/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Credit Note created successfully."))}

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
    case DebCre.update_credit_note(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_credit_note: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/CreditNote/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Credit Note updated successfully."))}

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
    params = params |> FullCircleWeb.Helpers.put_into_matchers("doc_date", params["note_date"])

    changeset =
      StdInterface.changeset(
        CreditNote,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket =
      assign(socket, form: to_form(changeset))
      |> FullCircleWeb.Helpers.assign_got_error(
        :details_got_error,
        changeset,
        :credit_note_details
      )
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
    <div class="w-9/12 mx-auto border rounded-lg border-cyan-500 bg-cyan-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.error_box changeset={@form.source} />
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <.input type="hidden" field={@form[:note_no]} />
        <div class="flex flex-row flex-nowrap">
          <div class="w-[41%]">
            <.input type="hidden" field={@form[:contact_id]} />
            <.input
              field={@form[:contact_name]}
              label={gettext("Credit Note To")}
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
          <div class="w-[12%]">
            <.input field={@form[:note_date]} label={gettext("Credit Note Date")} type="date" />
          </div>
          <div class="w-[12%]">
            <.input
              feedback={true}
              type="number"
              readonly
              field={@form[:note_balance]}
              label={gettext("Credit Note Balance")}
              value={Ecto.Changeset.fetch_field!(@form.source, :note_balance)}
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
              id={@form[:note_no].value}
              href="#"
              phx-hook="copyAndOpen"
              copy-text={@form[:note_no].value}
              goto-url="https://myinvois.hasil.gov.my/newdocument"
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
              href={"https://myinvois.hasil.gov.my/documents/#{@form[:e_inv_uuid].value}"}
            >
              Open E-Invoice
            </.link>
          </div>
          <div class="shrink-0 ml-2 mt-1">
            <% {url, qrcode} = FullCircle.Helpers.e_invoice_validation_url_qrcode(@form.source.data, 1) %>
            <.link target="_blank" href={url}>
              {qrcode |> raw}
            </.link>
          </div>
        </div>

        <div class="flex flex-row gap-2 flex-nowrap w-2/3 mx-auto text-center mt-5">
          <div
            id="credit-note-details-tab"
            phx-click={
              JS.hide(to: "#match-trans")
              |> JS.hide(to: "#query-match-trans")
              |> JS.remove_class("active", to: "#match-trans-tab")
              |> JS.show(to: "#credit-note-details")
              |> JS.add_class("active")
            }
            class="active basis-1/2 tab"
          >
            {gettext("Details")} =
            <span
              :if={!Decimal.eq?(Ecto.Changeset.fetch_field!(@form.source, :note_amount), 0)}
              class="font-normal text-rose-700"
            >
              {Ecto.Changeset.fetch_field!(@form.source, :note_amount)
              |> Number.Delimit.number_to_delimited()}
            </span>
            <span class="text-rose-500">
              <.icon :if={@details_got_error} name="hero-exclamation-triangle-mini" class="h-5 w-5" />
            </span>
          </div>

          <div
            id="match-trans-tab"
            phx-click={
              JS.show(to: "#match-trans")
              |> JS.add_class("active")
              |> JS.hide(to: "#credit-note-details")
              |> JS.remove_class("active", to: "#credit-note-details-tab")
              |> JS.show(to: "#query-match-trans")
            }
            class="basis-1/2 tab"
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
        </div>

        <.live_component
          module={FullCircleWeb.CreditNoteLive.DetailComponent}
          id="credit-note-details"
          klass="text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
          doc_name="CreditNote"
          detail_name={:credit_note_details}
          form={@form}
          taxcodetype="taxcode"
          doc_desc_amount={:note_desc_amount}
          doc_tax_amount={:note_tax_amount}
          doc_detail_amount={:note_amount}
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
            type="CreditNote"
          />
          <.print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="CreditNote"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="CreditNote"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="credit_notes"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="CreditNote"
            doc_no={@form.data.note_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>
    <.live_component
      module={FullCircleWeb.ReceiptLive.QryMatcherComponent}
      id="query-match-trans"
      klass="hidden w-9/12 mx-auto text-center border-4 bg-green-200 mt-4 p-3 rounded-lg border-green-800"
      query={@query}
      query_match_trans={@query_match_trans}
      form={@form}
      cannot_match_doc_type={~w(CreditNote Receipt DebitNote Payment)}
      doc_no_field={:note_no}
      current_company={@current_company}
      current_user={@current_user}
    />
    """
  end
end
