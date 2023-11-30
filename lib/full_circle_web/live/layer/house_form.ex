defmodule FullCircleWeb.LayerLive.HouseForm do
  use FullCircleWeb, :live_view
  alias FullCircle.StdInterface
  alias FullCircle.Layer.House

  @impl true
  def mount(params, _session, socket) do
    id = params["house_id"]

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
    |> assign(page_title: gettext("New House"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(House, %House{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    account = FullCircle.Layer.get_house!(id, socket.assigns.current_company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit House"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(House, account, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event("add_wage", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:house_harvest_wages)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_wage", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :house_harvest_wages)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("validate", %{"house" => params}, socket) do
    changeset =
      StdInterface.changeset(
        House,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"house" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           House,
           "house",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/houses")
         |> put_flash(:info, "#{gettext("House deleted successfully.")}")}

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
           House,
           "house",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/houses/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("House created successfully.")}")}

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
           House,
           "house",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/houses/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("House updated successfully.")}")}

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
    <div class="w-3/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-6">
            <.input field={@form[:house_no]} label={gettext("House")} />
          </div>
          <div class="col-span-6">
            <.input field={@form[:capacity]} label={gettext("Capacity")} type="number" />
          </div>
        </div>

        <div class="font-bold flex flex-row text-center mt-2">
          <div class="w-[25%]"><%= gettext("Lower Trays") %></div>
          <div class="w-[25%]"><%= gettext("Upper Tray") %></div>
          <div class="w-[25%]"><%= gettext("Wages") %></div>
          <div class="w-[3%]" />
        </div>

        <.inputs_for :let={wg} field={@form[:house_harvest_wages]}>
          <div class={"flex flex-row  #{if(wg[:delete].value == true and Enum.count(wg.errors) == 0, do: "hidden", else: "")}"}>
            <div class="w-[25%]">
              <.input type="number" field={wg[:ltry]} />
            </div>
            <div class="w-[25%]">
              <.input field={wg[:utry]} type="number" />
            </div>
            <div class="w-[25%]">
              <.input type="number" field={wg[:wages]} step="0.01"/>
            </div>
            <div class="w-[3%] mt-1.5 text-rose-500">
              <.link phx-click={:delete_wage} phx-value-index={wg.index}>
                <Heroicons.trash solid class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(wg, :delete) %>
            </div>
          </div>
        </.inputs_for>

        <div class="my-2">
          <.link phx-click={:add_wage} class="text-orange-500 hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Wage") %>
          </.link>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            new_url={~p"/companies/#{@current_company.id}/houses/new"}
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_house, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All House Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="houses"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
