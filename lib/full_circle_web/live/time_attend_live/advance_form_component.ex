defmodule FullCircleWeb.TimeAttendLive.AdvanceFormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.HR.{Advance}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(
           Advance,
           assigns.obj,
           %{},
           assigns.current_company
         )
       )
     )}
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
        send(self(), {:refresh_page_sn, obj})
        {:noreply, socket}

      {:error, _failed_operation, changeset, _} ->
        send(self(), {:error, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
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
        send(self(), {:refresh_page_sn, obj})
        {:noreply, socket}

      {:error, _failed_operation, changeset, _} ->
        send(self(), {:error, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
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
    <div class="">
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
        <p :if={!is_nil(@form.source.data.pay_slip_no)} class="w-full text-xl text-center font-bold">
          <%= @form.source.data.pay_slip_no %>
        </p>
        <%= Phoenix.HTML.Form.hidden_input(@form, :slip_no) %>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input feedback={true} field={@form[:slip_date]} label={gettext("Date")} type="date" />
          </div>
          <div class="col-span-5">
            <%= Phoenix.HTML.Form.hidden_input(@form, :employee_id) %>
            <.input
              field={@form[:employee_name]}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="col-span-4">
            <%= Phoenix.HTML.Form.hidden_input(@form, :funds_account_id) %>
            <.input
              field={@form[:funds_account_name]}
              label={gettext("Funds From")}
              phx-hook="tributeAutoComplete"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-9">
            <.input field={@form[:note]} label={gettext("Note")} />
          </div>
          <div class="col-span-3">
            <.input field={@form[:amount]} label={gettext("Amount")} type="number" step="0.0001" />
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.save_button form={@form} />
          <.link phx-click={:modal_cancel} class="orange button">
            <%= gettext("Cancel") %>
          </.link>
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
