defmodule FullCircleWeb.HolidayLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.Holiday
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["holiday_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
        :copy -> mount_copy(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Holiday"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Holiday, %Holiday{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    holiday = StdInterface.get!(Holiday, id)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Holiday"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Holiday, holiday, %{}, socket.assigns.current_company))
    )
  end

  defp mount_copy(socket, id) do
    obj =
      StdInterface.get!(Holiday, id)

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("Copying Holiday"))
    |> assign(current_company: socket.assigns.current_company)
    |> assign(current_user: socket.assigns.current_user)
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Holiday,
          %Holiday{},
          %{
            name: obj.name <> " - Copy",
            short_name: obj.short_name
          },
          socket.assigns.current_company
        )
      )
    )
  end

  @impl true
  def handle_event("validate", %{"holiday" => params}, socket) do
    changeset =
      StdInterface.changeset(
        Holiday,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"holiday" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case FullCircle.StdInterface.delete(
           Holiday,
           "holiday",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/holidays")
         |> put_flash(:info, "#{gettext("Holiday deleted successfully.")}")}

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

  defp save(socket, :new, params) do
    case StdInterface.create(
           Holiday,
           "holiday",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/holidays/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Holiday created successfully.")}")}

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
    case StdInterface.update(
           Holiday,
           "holiday",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/holidays/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Holiday updated successfully.")}")}

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-4/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="holiday-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="w-full"
      >
        <.input field={@form[:name]} label={gettext("Holiday Name")} />
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-6">
            <.input field={@form[:short_name]} label={gettext("Short Name")} />
          </div>
          <div class="col-span-6">
            <.input field={@form[:holidate]} label={gettext("Holiday Date")} type="date" />
          </div>
        </div>
        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            new_url={~p"/companies/#{@current_company.id}/holidays/new"}
          />
          <%= if @live_action == :edit and
                 FullCircle.Authorization.can?(@current_user, :delete_holiday, @current_company) do %>
            <.delete_confirm_modal
              id="delete-holiday"
              msg1={gettext("All Holiday Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#holiday-form") |> JS.hide(to: "#delete-holiday-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="holidays"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
