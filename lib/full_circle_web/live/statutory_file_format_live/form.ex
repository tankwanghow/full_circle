defmodule FullCircleWeb.StatutoryFileFormatLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{FileSpec, StatutoryConfig}

  @impl true
  def mount(params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_statutory_config,
         socket.assigns.current_company
       ) do
      com_id = socket.assigns.current_company.id
      code = params["code"] || ""

      {name, renderer, spec_json} =
        if code != "" do
          case StatutoryConfig.list_versions(:file_format, com_id) |> Enum.find(&(&1.code == code)) do
            nil ->
              {"", "text", "{}"}

            newest ->
              {newest.name, newest.renderer, Jason.encode!(newest.spec, pretty: true)}
          end
        else
          {"", "text", "{}"}
        end

      {:ok,
       socket
       |> assign(page_title: gettext("New File Format Version"))
       |> assign(
         form: %{
           "code" => code,
           "name" => name,
           "effective_from" => Date.to_iso8601(Date.utc_today()),
           "renderer" => renderer,
           "spec" => spec_json,
           "pay_month" => "#{Timex.today().month}",
           "pay_year" => "#{Timex.today().year}",
           "employer_code" => ""
         }
       )
       |> assign(preview_lines: nil)
       |> assign(preview_error: nil)
       |> assign(spec_errors: [])
       |> assign(save_errors: [])}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"file_format" => params}, socket) do
    {:noreply,
     socket
     |> assign(form: Map.merge(socket.assigns.form, params))
     |> assign_spec_errors(params["spec"])}
  end

  @impl true
  def handle_event("preview", params, socket) do
    form = Map.merge(socket.assigns.form, Map.get(params, "file_format", %{}))
    socket = assign(socket, form: form)

    with {:ok, _spec} <- decode_and_validate_spec(form["spec"], socket),
         month <- String.to_integer(form["pay_month"]),
         year <- String.to_integer(form["pay_year"]),
         {:ok, {_filename, text}} <-
           StatutoryConfig.render_file(
             socket.assigns.current_company.id,
             form["code"],
             month,
             year,
             form["employer_code"]
           ) do
      lines = text |> String.split(~r/\r?\n/, trim: true) |> Enum.take(20)

      {:noreply,
       socket
       |> assign(preview_lines: lines)
       |> assign(preview_error: nil)}
    else
      {:error, msg} ->
        {:noreply, socket |> assign(preview_lines: nil) |> assign(preview_error: msg)}

      _ ->
        {:noreply,
         socket
         |> assign(preview_lines: nil)
         |> assign(preview_error: gettext("fix spec errors before preview"))}
    end
  end

  @impl true
  def handle_event("save", %{"file_format" => params}, socket) do
    with {:ok, spec} <- decode_and_validate_spec(params["spec"], socket) do
      attrs = %{
        code: params["code"],
        name: params["name"],
        effective_from: params["effective_from"],
        renderer: params["renderer"] || "text",
        spec: spec
      }

      case StatutoryConfig.save_file_format(attrs, socket.assigns.current_company, socket.assigns.current_user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("File format saved."))
           |> push_navigate(
             to: ~p"/companies/#{socket.assigns.current_company.id}/statutory_file_formats"
           )}

        {:error, cs} ->
          {:noreply,
           socket
           |> assign(form: Map.merge(socket.assigns.form, params))
           |> assign(save_errors: changeset_errors(cs))}

        :not_authorise ->
          {:noreply,
           put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
      end
    else
      {:error, _} ->
        {:noreply,
         socket
         |> assign(form: Map.merge(socket.assigns.form, params))
         |> assign(save_errors: [gettext("fix spec errors before saving")])}
    end
  end

  defp decode_and_validate_spec(nil, _socket), do: {:error, "spec is required"}

  defp decode_and_validate_spec(json, socket) when is_binary(json) do
    with {:ok, spec} <- Jason.decode(json),
         :ok <- FileSpec.validate(spec, StatutoryConfig.file_format_variables(socket.assigns.current_company.id)) do
      {:ok, spec}
    else
      {:error, %Jason.DecodeError{}} -> {:error, gettext("invalid JSON")}
      {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
      {:error, msg} -> {:error, msg}
    end
  end

  defp assign_spec_errors(socket, spec_json) when is_binary(spec_json) do
    errors =
      case Jason.decode(spec_json) do
        {:ok, spec} ->
          case FileSpec.validate(spec, StatutoryConfig.file_format_variables(socket.assigns.current_company.id)) do
            :ok -> []
            {:error, errs} -> errs
          end

        {:error, %Jason.DecodeError{}} ->
          [gettext("invalid JSON")]
      end

    assign(socket, spec_errors: errors)
  end

  defp assign_spec_errors(socket, _), do: assign(socket, spec_errors: [])

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-9/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-900/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={%{}} id="object-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <div class="grid grid-cols-12 gap-2 mb-2">
          <div class="col-span-3">
            <label class="block text-sm font-medium">{gettext("Code")}</label>
            <input
              type="text"
              name="file_format[code]"
              value={@form["code"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-3">
            <label class="block text-sm font-medium">{gettext("Name")}</label>
            <input
              type="text"
              name="file_format[name]"
              value={@form["name"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-2">
            <label class="block text-sm font-medium">{gettext("Effective From")}</label>
            <input
              type="date"
              name="file_format[effective_from]"
              value={@form["effective_from"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-2">
            <label class="block text-sm font-medium">{gettext("Renderer")}</label>
            <input
              type="text"
              name="file_format[renderer]"
              value={@form["renderer"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
        </div>

        <label class="block text-sm font-medium">{gettext("Spec (JSON)")}</label>
        <textarea
          name="file_format[spec]"
          rows="18"
          class="w-full font-mono text-sm border rounded px-2 py-1 dark:bg-gray-800"
        >{@form["spec"]}</textarea>
        <p :for={msg <- @spec_errors} class="text-rose-600 text-sm">{msg}</p>
        <p :for={msg <- @save_errors} class="text-rose-600 text-sm">{msg}</p>

        <div class="mt-4 border rounded p-3 bg-white dark:bg-gray-800">
          <p class="font-semibold mb-2">{gettext("Preview")}</p>
          <div class="grid grid-cols-12 gap-2">
            <div class="col-span-2">
              <label class="block text-sm font-medium">{gettext("Month")}</label>
              <input
                type="number"
                name="file_format[pay_month]"
                min="1"
                max="12"
                value={@form["pay_month"]}
                class="w-full border rounded px-2 py-1 dark:bg-gray-800"
              />
            </div>
            <div class="col-span-2">
              <label class="block text-sm font-medium">{gettext("Year")}</label>
              <input
                type="number"
                name="file_format[pay_year]"
                value={@form["pay_year"]}
                class="w-full border rounded px-2 py-1 dark:bg-gray-800"
              />
            </div>
            <div class="col-span-3">
              <label class="block text-sm font-medium">{gettext("Employer Code")}</label>
              <input
                type="text"
                name="file_format[employer_code]"
                value={@form["employer_code"]}
                class="w-full border rounded px-2 py-1 dark:bg-gray-800"
              />
            </div>
            <div class="col-span-3 mt-6">
              <button type="button" phx-click="preview" class="blue button">
                {gettext("Preview")}
              </button>
            </div>
          </div>
          <p :if={@preview_error} class="text-rose-600 mt-2">{@preview_error}</p>
          <pre :if={@preview_lines} class="mt-2 font-mono text-xs overflow-x-auto bg-gray-100 dark:bg-gray-900 p-2 rounded">
            {Enum.join(@preview_lines, "\n")}
          </pre>
        </div>

        <div class="flex justify-center mt-4 gap-2">
          <button type="submit" class="blue button">{gettext("Save")}</button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/statutory_file_formats"}
            class="blue button"
          >
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end