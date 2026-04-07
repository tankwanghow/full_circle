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
        socket.assigns.current_company,
        socket.assigns.current_user
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
    |> assign_text_fields(%EInvMeta{})
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
    |> assign_text_fields(obj)
  end

  defp assign_text_fields(socket, obj) do
    prod = obj.production || %{}
    sb = obj.sandbox || %{}
    paths = obj.paths || %{}
    unit_map = obj.unit_code_map || %{}
    merged_units = Map.merge(EInvMetas.default_unit_codes(), unit_map)

    socket
    |> assign(prod_text: map_to_text(prod))
    |> assign(sandbox_text: map_to_text(sb))
    |> assign(paths_text: map_to_text(paths))
    |> assign(unit_code_text: map_to_text(merged_units))
  end

  defp map_to_text(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(", ")
  end

  defp text_to_map(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn entry, acc ->
      case String.split(entry, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  def handle_event("validate", %{"e_inv_meta" => params} = full_params, socket) do
    socket =
      socket
      |> assign(prod_text: full_params["prod_text"] || socket.assigns.prod_text)
      |> assign(sandbox_text: full_params["sandbox_text"] || socket.assigns.sandbox_text)
      |> assign(paths_text: full_params["paths_text"] || socket.assigns.paths_text)
      |> assign(unit_code_text: full_params["unit_code_text"] || socket.assigns.unit_code_text)

    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"e_inv_meta" => params} = full_params, socket) do
    params =
      params
      |> Map.put("production", text_to_map(full_params["prod_text"] || ""))
      |> Map.put("sandbox", text_to_map(full_params["sandbox_text"] || ""))
      |> Map.put("paths", text_to_map(full_params["paths_text"] || ""))
      |> Map.put("unit_code_map", text_to_map(full_params["unit_code_text"] || ""))

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
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="flex flex-nowrap gap-1 items-end">
          <div class="w-[20%]">
            <.input
              field={@form[:environment]}
              label={gettext("Environment")}
              type="select"
              options={[{"Production", "production"}, {"Sandbox", "sandbox"}]}
            />
          </div>
        </div>

        <div class="mt-2">
          <label class="font-medium text-sm">
            {gettext("Production")}
            <span class="text-xs text-gray-500">(api_base, id_base, client_id, client_secret1, client_secret2, expiration)</span>
          </label>
          <textarea
            name="prod_text"
            rows="3"
            class="w-full font-mono text-sm border rounded p-2 mt-1"
          >{@prod_text}</textarea>
        </div>

        <div class="mt-2">
          <label class="font-medium text-sm">
            {gettext("Sandbox")}
            <span class="text-xs text-gray-500">(api_base, id_base, client_id, client_secret1, client_secret2, expiration)</span>
          </label>
          <textarea
            name="sandbox_text"
            rows="3"
            class="w-full font-mono text-sm border rounded p-2 mt-1"
          >{@sandbox_text}</textarea>
        </div>

        <div class="mt-2">
          <label class="font-medium text-sm">
            {gettext("API Paths")}
            <span class="text-xs text-gray-500">(login, search, get_doc, get_doc_details, submit)</span>
          </label>
          <textarea
            name="paths_text"
            rows="3"
            class="w-full font-mono text-sm border rounded p-2 mt-1"
          >{@paths_text}</textarea>
        </div>

        <div class="mt-2">
          <label class="font-medium text-sm">
            {gettext("LHDN Unit Code Mapping")}
            <span class="text-xs text-gray-500">(FC Unit=LHDN Code, comma separated)</span>
          </label>
          <textarea
            name="unit_code_text"
            rows="3"
            class="w-full font-mono text-sm border rounded p-2 mt-1"
          >{@unit_code_text}</textarea>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.save_button form={@form} />
          <.link :if={@live_action != :new} navigate="" class="orange button">
            {gettext("Cancel")}
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
