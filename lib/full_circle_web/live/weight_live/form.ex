defmodule FullCircleWeb.WeighingLive.Form do
  alias FullCircle.WeightBridge.Weighing
  use FullCircleWeb, :live_view

  alias FullCircle.WeightBridge.{Weighing}
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["weighing_id"]

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
    |> assign(page_title: gettext("New Weighing"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Weighing,
          %Weighing{},
          %{note_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    obj = StdInterface.get!(Weighing, id)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Weighing") <> " " <> obj.note_no)
    |> assign(
      :form,
      to_form(StdInterface.changeset(Weighing, obj, %{}, socket.assigns.current_company))
    )
  end

  def handle_event("validate", %{"weighing" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"weighing" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Weighing,
           "weighing",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/Weighing")
         |> put_flash(:info, "#{gettext("Weighing deleted successfully.")}")}

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
           Weighing,
           "weighing",
           params
           |> Map.merge(%{"note_no" => FullCircle.Helpers.gen_temp_id(6) |> String.upcase()}),
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _obj} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/Weighing")
         |> put_flash(:info, "#{gettext("Weighing created successfully.")}")}

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
           Weighing,
           "weighing",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _obj} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/Weighing")
         |> put_flash(:info, "#{gettext("Weighing updated successfully.")}")}

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
        Weighing,
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
    <div class="w-6/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <.input type="hidden" field={@form[:note_no]} />
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input field={@form[:note_date]} label={gettext("Date")} type="date" />
          </div>
          <div class="col-span-3">
            <.input field={@form[:vehicle_no]} label={gettext("Vehicle No")} />
          </div>
          <div class="col-span-6">
            <.input field={@form[:good_name]} label={gettext("Good Name")} />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input
              field={@form[:gross]}
              label={gettext("Gross")}
              phx-hook="calculatorInput"
              klass="text-right"
            />
          </div>
          <div class="col-span-3">
            <.input
              field={@form[:tare]}
              label={gettext("Tare")}
              phx-hook="calculatorInput"
              klass="text-right"
            />
          </div>
          <div class="col-span-3">
            <.input tabindex="-1" readonly field={@form[:nett]} label={gettext("Nett")} type="number" />
          </div>
          <div class="col-span-3">
            <.input field={@form[:unit]} label={gettext("Unit")} />
          </div>
        </div>
        <div>
          <.input field={@form[:note]} label={gettext("Note")} />
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="Weighing"
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_weighing, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("Weighing, will be Deleted!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Weighing"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Weighing"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="weighings"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="Weighing"
            doc_no={@form.data.note_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
