defmodule FullCircleWeb.JournalLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.JournalEntry
  alias FullCircle.Accounting.{Journal}
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["journal_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Journal"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Journal,
          %Journal{},
          %{journal_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      JournalEntry.get_journal!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Journal") <> " " <> object.journal_no)
    |> assign(
      :form,
      to_form(StdInterface.changeset(Journal, object, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event("add_trans", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:transactions, %{
        doc_type: "Journal",
        company_id: socket.assigns.current_company.id
      })
      |> Map.put(:action, socket.assigns.live_action)
      |> Journal.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_trans", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :transactions)
      |> Map.put(:action, socket.assigns.live_action)
      |> Journal.compute_balance()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["journal", "transactions", id, "account_name"],
          "journal" => params
        },
        socket
      ) do
    detail = params["transactions"][id]

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
      |> FullCircleWeb.Helpers.merge_detail("transactions", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["journal", "transactions", id, "contact_name"],
          "journal" => params
        },
        socket
      ) do
    detail = params["transactions"][id]

    {detail, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "contact_name",
        "contact_id",
        &FullCircle.Accounting.get_contact_by_name/3
      )

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("transactions", id, detail)

    validate(params, socket)
  end

  def handle_event("validate", %{"journal" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"journal" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case JournalEntry.create_journal(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_journal: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Journal/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Journal created successfully.")}")}

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
    case JournalEntry.update_journal(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_journal: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Journal/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Journal updated successfully.")}")}

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
        Journal,
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
    <div class="w-6/12 mx-auto border rounded-lg border-pink-500 bg-pink-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <.input type="hidden" field={@form[:journal_no]} />
        <div class="flex flex-row flex-nowarp">
          <div class="w-1/4">
            <.input field={@form[:journal_date]} label={gettext("Invoice Date")} type="date" />
          </div>
        </div>

        <div
          id="transactions"
          class="text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
        >
          <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
            <div class="detail-header w-[25%]">{gettext("Account")}</div>
            <div class="detail-header w-[25%]">{gettext("Contact")}</div>
            <div class="detail-header w-[30%]">{gettext("Particulars")}</div>
            <div class="detail-header w-[17%]">{gettext("Amount")}</div>
            <div class="w-[3%]">{gettext("")}</div>
          </div>

          <.inputs_for :let={dtl} field={@form[:transactions]}>
            <div class={"flex flex-row flex-wrap #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
              <.input type="hidden" field={dtl[:account_id]} />
              <div class="w-[25%]">
                <.input
                  field={dtl[:account_name]}
                  phx-hook="tributeAutoComplete"
                  url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
                />
              </div>
              <.input type="hidden" field={dtl[:contact_id]} />
              <div class="w-[25%]">
                <.input
                  field={dtl[:contact_name]}
                  phx-hook="tributeAutoComplete"
                  url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
                />
              </div>
              <div class="w-[30%]"><.input field={dtl[:particulars]} /></div>
              <div class="w-[17%]">
                <.input type="number" step="0.01" field={dtl[:amount]} />
              </div>
              <div class="w-[3%] mt-1 text-rose-500">
                <.link phx-click={:delete_trans} phx-value-index={dtl.index} tabindex="-1">
                  <.icon name="hero-trash-solid" class="h-5 w-5" />
                </.link>
                <.input type="hidden" field={dtl[:delete]} value={"#{dtl[:delete].value}"} />
              </div>
            </div>
          </.inputs_for>
          <div class="flex flex-row flex-wrap">
            <div class="w-[25%] text-orange-500 font-bold pt-2">
              <.link phx-click={:add_trans}>
                <.icon name="hero-plus-circle" class="w-5 h-5" />{gettext("Add Entry")}
              </.link>
            </div>
            <div class="w-[55%] pt-2 pr-2 font-semibold text-right">Balance</div>
            <div class="w-[17%] font-semi bold">
              <.input
                type="number"
                feedback={true}
                readonly
                tabindex="-1"
                field={@form[:journal_balance]}
                value={Ecto.Changeset.fetch_field!(@form.source, :journal_balance)}
              />
            </div>
          </div>
        </div>

        <div class="flex flex-row justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="Journal"
          />
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Journal"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Journal"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="journals"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
