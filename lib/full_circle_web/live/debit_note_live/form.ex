defmodule FullCircleWeb.DebitNoteLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{Accounting, DebCre}
  alias FullCircle.DebCre.{DebitNote}
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
     |> assign(query: %{from: from, to: to})
     |> assign(query_match_trans: [])}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Debit Note"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          DebitNote,
          %DebitNote{},
          %{note_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      DebCre.get_debit_note!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      StdInterface.changeset(DebitNote, object, %{}, socket.assigns.current_company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Debit Note") <> " " <> object.note_no)
    |> assign(:form, to_form(cs))
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:debit_note_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> DebitNote.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :debit_note_details)
      |> Map.put(:action, socket.assigns.live_action)
      |> DebitNote.compute_balance()

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
        doc_type: "DebitNote",
        all_matched_amount: match_tran.all_matched_amount,
        balance: 0.00,
        match_amount: Decimal.negate(match_tran.balance) |> Decimal.round(2)
      })

    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:transaction_matchers, match_tran)
      |> Map.put(:action, socket.assigns.live_action)
      |> DebitNote.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_match_tran", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :transaction_matchers)
      |> Map.put(:action, socket.assigns.live_action)
      |> DebitNote.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["debit_note", "contact_name"], "debit_note" => params},
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
          "_target" => ["debit_note", "debit_note_details", id, "account_name"],
          "debit_note" => params
        },
        socket
      ) do
    detail = params["debit_note_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("debit_note_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["debit_note", "debit_note_details", id, "tax_code_name"],
          "debit_note" => params
        },
        socket
      ) do
    detail = params["debit_note_details"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("debit_note_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"debit_note" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"debit_note" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case DebCre.create_debit_note(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_debit_note: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/DebitNote/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Debit Note created successfully."))}

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
    case DebCre.update_debit_note(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_debit_note: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/DebitNote/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Debit Note updated successfully."))}

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
        DebitNote,
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
    <div class="w-9/12 mx-auto border rounded-lg border-emerald-500 bg-emerald-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <%= Phoenix.HTML.Form.hidden_input(@form, :note_no) %>
        <div class="flex flex-row flex-nowarp">
          <div class="w-6/12 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :contact_id) %>
            <.input
              field={@form[:contact_name]}
              label={gettext("Debit Note To")}
              phx-hook="tributeAutoComplete"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="grow shrink w-3/12">
            <.input field={@form[:note_date]} label={gettext("Debit Note Date")} type="date" />
          </div>
          <div class="grow shrink w-3/12">
            <.input
              feedback={true}
              type="number"
              readonly
              field={@form[:note_balance]}
              label={gettext("Debit Note Balance")}
              value={Ecto.Changeset.fetch_field!(@form.source, :note_balance)}
            />
          </div>
        </div>
        <div class="flex flex-row gap-2 flex-nowrap w-2/3 mx-auto text-center mt-5">
          <div
            id="debit-note-details-tab"
            phx-click={
              JS.hide(to: "#match-trans")
              |> JS.hide(to: "#query-match-trans")
              |> JS.remove_class("active", to: "#match-trans-tab")
              |> JS.show(to: "#debit-note-details")
              |> JS.add_class("active")
            }
            class="active basis-1/2 tab"
          >
            <%= gettext("Details") %> =
            <span
              :if={!Decimal.eq?(Ecto.Changeset.fetch_field!(@form.source, :note_amount), 0)}
              class="font-normal text-rose-700"
            >
              <%= Ecto.Changeset.fetch_field!(@form.source, :note_amount)
              |> Number.Delimit.number_to_delimited() %>
            </span>
          </div>

          <div
            id="match-trans-tab"
            phx-click={
              JS.show(to: "#match-trans")
              |> JS.add_class("active")
              |> JS.hide(to: "#debit-note-details")
              |> JS.remove_class("active", to: "#debit-note-details-tab")
              |> JS.show(to: "#query-match-trans")
            }
            class="basis-1/2 tab"
          >
            <%= gettext("Matchers") %> =
            <span
              :if={!Decimal.eq?(Ecto.Changeset.fetch_field!(@form.source, :matched_amount), 0)}
              class="font-normal text-rose-700"
            >
              <%= Ecto.Changeset.fetch_field!(@form.source, :matched_amount)
              |> Decimal.new()
              |> Decimal.abs()
              |> Number.Delimit.number_to_delimited() %>
            </span>
          </div>
        </div>

        <.live_component
          module={FullCircleWeb.CreditNoteLive.DetailComponent}
          id="debit-note-details"
          klass="text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
          doc_name="DebitNote"
          detail_name={:debit_note_details}
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
            type="DebitNote"
          />
          <.print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="DebitNote"
            doc_id={@id}
            class="blue button"
          />
          <.pre_print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="DebitNote"
            doc_id={@id}
            class="blue button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="debit_notes"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="DebitNote"
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
      balance_ve="-ve"
      doc_no_field={:note_no}
      current_company={@current_company}
      current_user={@current_user}
    />
    """
  end
end
