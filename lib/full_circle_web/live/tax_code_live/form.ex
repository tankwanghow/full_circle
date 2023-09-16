defmodule FullCircleWeb.TaxCodeLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.TaxCode
  alias FullCircle.Accounting
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["tax_code_id"]

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
    |> assign(title: gettext("New TaxCode"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(TaxCode, %TaxCode{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    obj =
      Accounting.get_tax_code!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(title: gettext("Edit TaxCode"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(TaxCode, obj, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["tax_code", "account_name"], "tax_code" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "account_name",
        "account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"tax_code" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"tax_code" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           TaxCode,
           "tax_code",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/tax_codes")
         |> put_flash(:info, "#{gettext("TaxCode deleted successfully.")}")}

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
           TaxCode,
           "tax_code",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/tax_codes/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("TaxCode created successfully.")}")}

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
           TaxCode,
           "tax_code",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/tax_codes/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("TaxCode updated successfully.")}")}

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
        TaxCode,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-5/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <div class="flex flex-row gap-1">
          <div class="w-[60%]">
            <.input field={@form[:code]} label={gettext("Code")} />
          </div>
          <div class="w-[40%]">
            <.input
              field={@form[:tax_type]}
              label={gettext("TaxCode Type")}
              type="select"
              options={FullCircle.Accounting.tax_types()}
            />
          </div>
        </div>
        <div class="flex flex-row gap-1">
          <div class="w-[40%]">
            <.input
              field={@form[:rate]}
              type="number"
              step="0.0001"
              label={gettext("Rate (6% = 0.06, 10% = 0.1)")}
            />
          </div>
          <div class="w-[60%]">
            <%= Phoenix.HTML.Form.hidden_input(@form, :account_id) %>
            <.input
              field={@form[:account_name]}
              label={gettext("Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
        </div>
        <.input
          field={@form[:descriptions]}
          label={gettext("Descriptions")}
          type="textarea"
          rows={10}
        />

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            new_url={~p"/companies/#{@current_company.id}/tax_codes/new"}
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All TaxCode Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="tax_codes"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
