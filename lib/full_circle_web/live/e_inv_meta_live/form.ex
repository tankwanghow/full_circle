defmodule FullCircleWeb.EInvMetaLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.EInvMetas.EInvMeta
  alias FullCircle.EInvMetas
  alias FullCircle.StdInterface
  import Ecto.Query, warn: false

  @impl true
  def mount(_params, _session, socket) do
    obj =
      EInvMetas.get_by_company_id!(
        socket.assigns.current_company.id,
        socket.assigns.current_user.id
      )

    socket =
      case obj do
        nil -> mount_new(socket)
        _ -> mount_edit(socket, obj)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New E-Invoice Meta Data"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(EInvMeta, %EInvMeta{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, obj) do
    socket
    |> assign(live_action: :edit)
    |> assign(id: obj.id)
    |> assign(page_title: gettext("Edit E-Invoice Meta Data"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(EInvMeta, obj, %{}, socket.assigns.current_company))
    )
  end

  def handle_event("validate", %{"e_inv_meta" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"e_inv_meta" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           EInvMeta,
           "e_inv_meta",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/e_inv_meta")
         |> put_flash(:info, "#{gettext("E-Invoice Meta Data created successfully.")}")}

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
           EInvMeta,
           "e_inv_meta",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/e_inv_meta")
         |> put_flash(:info, "#{gettext("E-Invoice Meta Data updated successfully.")}")}

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
        EInvMeta,
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
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="flex flex-nowrap gap-1">
          <div class="w-[50%]">
            <.input field={@form[:e_inv_apibaseurl]} label={gettext("ApiBaseUrl")} />
          </div>
          <div class="w-[50%]">
            <.input field={@form[:e_inv_idsrvbaseurl]} label={gettext("IdSrvBaseUrl")} />
          </div>
        </div>

        <div class="flex flex-nowrap gap-1">
          <div class="w-[28%]">
            <.input field={@form[:e_inv_clientid]} label={gettext("Client Id")} />
          </div>
          <div class="w-[28%]">
            <.input field={@form[:e_inv_clientsecret1]} label={gettext("Client Secret 1")} />
          </div>
          <div class="w-[28%]">
            <.input field={@form[:e_inv_clientsecret2]} label={gettext("Client Secret 2")} />
          </div>
          <div class="w-[15%]">
            <.input
              field={@form[:e_inv_clientsecretexpiration]}
              label={gettext("Expiration")}
              type="date"
            />
          </div>
        </div>

        <div class="flex flex-nowrap gap-1">
          <div class="w-[25%]">
            <.input field={@form[:login_url]} label={gettext("Login Path")} />
          </div>
          <div class="w-[25%]">
            <.input field={@form[:search_url]} label={gettext("search_path")} />
          </div>
          <div class="w-[25%]">
            <.input field={@form[:get_doc_url]} label={gettext("Get Doc Path")} />
          </div>
          <div class="w-[25%]">
            <.input field={@form[:get_doc_details_url]} label={gettext("Get Detail Doc Path")} />
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.save_button form={@form} />
          <.link :if={@live_action != :new} navigate="" class="orange button">
            <%= gettext("Cancel") %>
          </.link>
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="e_inv_metas"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
