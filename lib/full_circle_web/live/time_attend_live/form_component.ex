defmodule FullCircleWeb.TimeAttendLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.HR.{TimeAttend}
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
           TimeAttend,
           assigns.obj,
           %{
             company_id: assigns.current_company.id,
             input_medium: "UserEntry",
             user_id: assigns.current_user.id
           },
           assigns.current_company,
           :data_entry_changeset
         )
       )
     )}
  end

  def handle_event(
        "validate",
        %{"_target" => ["time_attend", "employee_name"], "time_attend" => params},
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

  def handle_event("validate", %{"time_attend" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"time_attend" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case HR.delete_time_attendence(
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, obj} ->
        send(self(), {socket.assigns.deleted_info, obj})
        {:noreply, socket}

      {:error, changeset} ->
        send(self(), {socket.assigns.error_info, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
    end
  end

  defp save(socket, :new, params) do
    case(
      HR.create_time_attendence_by_entry(
        params,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
    ) do
      {:ok, obj} ->
        send(self(), {socket.assigns.created_info, obj})
        {:noreply, socket}

      {:error, changeset} ->
        send(self(), {socket.assigns.error_info, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
    end
  end

  defp save(socket, :edit, params) do
    case HR.update_time_attendence(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, obj} ->
        send(self(), {socket.assigns.updated_info, obj})
        {:noreply, socket}

      {:error, changeset} ->
        send(self(), {socket.assigns.error_info, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
    end
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        TimeAttend,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company,
        :data_entry_changeset
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
        <p class="w-full text-center text-xl border-2 border-orange-400 bg-orange-200 rounded-lg p-3 mb-3">
          <%= gettext("Warning! Minimum Data Integrity is Impose! Make sure your data is correct.") %>
        </p>
        <div class="grid grid-cols-12 gap-1 mb-2">
          <%= Phoenix.HTML.Form.hidden_input(@form, :input_medium) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :user_id) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :company_id) %>
          <div class="col-span-4">
            <%= Phoenix.HTML.Form.hidden_input(@form, :employee_id) %>
            <.input
              :if={@live_action == :new}
              feedback={true}
              field={@form[:employee_name]}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
            <.input
              :if={@live_action == :edit}
              feedback={true}
              field={@form[:employee_name]}
              label={gettext("Employee")}
              readonly
              tabindex="-1"
            />
          </div>
          <div class="col-span-2">
            <.input feedback={true} field={@form[:shift_id]} label={gettext("shift_id")} />
          </div>
          <div class="col-span-3">
            <.input
              feedback={true}
              field={@form[:punch_time_local]}
              label={gettext("Punch Date Time")}
              type="datetime-local"
            />
          </div>
          <div class="col-span-1">
            <.input
              feedback={true}
              field={@form[:flag]}
              label={gettext("Flag")}
              type="select"
              options={["IN", "OUT"]}
            />
          </div>
          <div class="col-span-2">
            <.input
              feedback={true}
              field={@form[:status]}
              label={gettext("Status")}
              type="select"
              options={["Draft", "Approved", "Paid"]}
            />
          </div>
        </div>

        <p class="text-center mt-2 text-sm text-gray-500">
          last touch using <%= @form.source.data.input_medium %> by <%= @form.source.data.email %> at <%= FullCircleWeb.Helpers.format_datetime(
            @form.source.data.updated_at,
            @current_company
          ) %>
        </p>

        <div class="flex justify-center gap-x-1 mt-2">
          <.save_button form={@form} />
          <.link phx-click={:modal_cancel} class="orange button">
            <%= gettext("Cancel") %>
          </.link>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_time_attendence, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("Deleting Time Attendence")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.exec("phx-remove", to: "#delete-object-modal")
              }
            />
          <% end %>
        </div>
      </.form>
    </div>
    """
  end
end
