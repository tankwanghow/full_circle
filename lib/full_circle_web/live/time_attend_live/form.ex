defmodule FullCircleWeb.TimeAttendLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.{TimeAttend}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["attend_id"]

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
    |> assign(page_title: gettext("New Attendence"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          TimeAttend,
          %TimeAttend{},
          %{
            company_id: socket.assigns.current_company.id,
            input_medium: "UserEntry",
            user_id: socket.assigns.current_user.id
          },
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    obj =
      HR.get_time_attendence!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Attendence"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          TimeAttend,
          obj,
          %{
            company_id: socket.assigns.current_company.id,
            input_medium: "UserEntry",
            user_id: socket.assigns.current_user.id
          },
          socket.assigns.current_company
        )
      )
    )
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
      {:ok, _obj} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/TimeAttend")
         |> put_flash(:info, "#{gettext("Attendence Deleted successfully.")}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
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
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/TimeAttend/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Attendence created successfully.")}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
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
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/TimeAttend/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Attendence updated successfully.")}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{list_errors_to_string(changeset.errors)}"
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
        TimeAttend,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company,
        :data_entry_changeset
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    IO.inspect(changeset)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-7/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <p class="w-full text-center text-xl border-2 border-orange-400 bg-orange-200 rounded-lg p-3 mb-3">
        <%= gettext("Warning! Minimum Data Integrity is Impose! Make sure your data is correct.") %>
      </p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-1 mb-2">
          <%= Phoenix.HTML.Form.hidden_input(@form, :input_medium) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :user_id) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :company_id) %>
          <div class="col-span-6">
            <%= Phoenix.HTML.Form.hidden_input(@form, :employee_id) %>
            <.input
              feedback={true}
              field={@form[:employee_name]}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="col-span-4">
            <.input
              feedback={true}
              field={@form[:punch_time_local]}
              label={gettext("Punch Date Time")}
              type="datetime-local"
            />
          </div>
          <div class="col-span-2">
            <.input
              feedback={true}
              field={@form[:flag]}
              label={gettext("Flag")}
              type="select"
              options={["IN", "OUT"]}
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
          <.form_action_button
            form={@form}
            live_action={@live_action}
            new_url={~p"/companies/#{@current_company.id}/TimeAttend/new"}
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_time_attendence, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("Deleting Time Attendence")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
        </div>
      </.form>
    </div>
    """
  end
end
