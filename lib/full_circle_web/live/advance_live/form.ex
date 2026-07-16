defmodule FullCircleWeb.AdvanceLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.{Advance}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["slip_id"]

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
    |> assign(readonly: false)
    |> assign(page_title: gettext("New Advance"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Advance,
          %Advance{},
          %{slip_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    obj =
      HR.get_advance!(id, socket.assigns.current_company, socket.assigns.current_user)

    # An advance already on a pay slip is shown read-only here; edit it via the Punch Card.
    readonly = not is_nil(obj.pay_slip_id)
    title = if readonly, do: gettext("View Advance"), else: gettext("Edit Advance")

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(readonly: readonly)
    |> assign(page_title: title <> " " <> obj.slip_no)
    |> assign(
      :form,
      to_form(StdInterface.changeset(Advance, obj, %{}, socket.assigns.current_company))
    )
  end

  def handle_event(
        "validate",
        %{"_target" => ["advance", "employee_name"], "advance" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "employee_name",
        "employee_id",
        &FullCircle.HR.get_employee_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["advance", "funds_account_name"], "advance" => params},
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

  def handle_event("validate", %{"advance" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"advance" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case(
      HR.create_advance(
        params,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
    ) do
      {:ok, %{create_advance: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Advance/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Advance created successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case HR.update_advance(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_advance: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Advance/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Advance updated successfully.")}")}

      {:error, :on_payslip} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This advance is on a pay slip — edit it via the Punch Card.")
         )}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        Advance,
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
    <div class="w-7/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <p :if={!is_nil(@form.source.data.pay_slip_no)} class="w-full text-xl text-center font-bold">
        {@form.source.data.pay_slip_no}
      </p>
      <div
        :if={@readonly}
        class="text-center bg-amber-200 border border-amber-500 rounded p-1 my-2"
      >
        {gettext("Read only — this advance is on a pay slip. Edit it via the Punch Card.")}
      </div>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <.input field={@form[:slip_no]} type="hidden" />
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input
              field={@form[:slip_date]}
              label={gettext("Date")}
              type="date"
              readonly={@readonly}
            />
          </div>
          <div class="col-span-5">
            <.input field={@form[:employee_id]} type="hidden" />
            <.input
              field={@form[:employee_name]}
              label={gettext("Employee")}
              readonly={@readonly}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="col-span-4">
            <.input field={@form[:funds_account_id]} type="hidden" />
            <.input
              field={@form[:funds_account_name]}
              label={gettext("Funds From")}
              readonly={@readonly}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-9">
            <.input field={@form[:note]} label={gettext("Note")} readonly={@readonly} />
          </div>
          <div class="col-span-3">
            <.input
              field={@form[:amount]}
              label={gettext("Amount")}
              type="number"
              step="0.0001"
              readonly={@readonly}
            />
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            :if={!@readonly}
            form={@form}
            live_action={@live_action}
            type="Advance"
            current_company={@current_company}
          />
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Advance"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Advance"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="advances"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="Advance"
            doc_no={@form.data.slip_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
