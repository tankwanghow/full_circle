defmodule FullCircleWeb.BankFileFormatLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_bank_payment_config,
         com
       ) do
      code = params["code"] || ""

      {name, spec_json} =
        case code != "" && Enum.find(BankPayment.list_formats(com.id), &(&1.code == code)) do
          %{} = newest -> {newest.name, Jason.encode!(newest.spec, pretty: true)}
          _ -> {"", "{}"}
        end

      profiles = BankPayment.list_profiles(com)

      {:ok,
       socket
       |> assign(
         page_title: gettext("New Bank File Format Version"),
         templates: BankPayment.templates(),
         profiles: profiles
       )
       |> assign(
         form: %{
           "code" => code,
           "name" => name,
           "effective_from" => Date.to_iso8601(BankPayment.today(com)),
           "spec" => spec_json,
           "template" => "",
           "profile_id" => (List.first(profiles) || %{id: ""}).id
         }
       )
       |> assign(
         preview_lines: nil,
         preview_error: nil,
         spec_errors: [],
         save_errors: [],
         confirm_replace: false
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"file_format" => params}, socket) do
    {:noreply,
     socket
     |> assign(form: Map.merge(socket.assigns.form, params), confirm_replace: false)
     |> assign_spec_errors(params["spec"])}
  end

  @impl true
  def handle_event("load_template", _params, socket) do
    case BankPayment.load_template(socket.assigns.form["template"] || "") do
      {:ok, t} ->
        form =
          Map.merge(socket.assigns.form, %{
            "code" => t["code"],
            "name" => t["name"],
            "spec" => Jason.encode!(t["spec"], pretty: true)
          })

        {:noreply, socket |> assign(form: form) |> assign_spec_errors(form["spec"])}

      {:error, msg} ->
        {:noreply, assign(socket, save_errors: [msg])}
    end
  end

  @impl true
  def handle_event("preview", _params, socket) do
    form = socket.assigns.form
    com = socket.assigns.current_company

    with {:ok, spec} <- decode_and_validate(form["spec"]),
         %{} = profile <-
           BankPayment.get_profile(form["profile_id"], com) ||
             {:error, gettext("choose a profile to preview with")},
         {:ok, text} <- BankPayment.preview(spec, profile, com) do
      {:noreply,
       assign(socket,
         preview_lines: text |> String.split(~r/\r?\n/, trim: true) |> Enum.take(20),
         preview_error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, preview_lines: nil, preview_error: msg)}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    form = Map.merge(socket.assigns.form, Map.get(params, "file_format", %{}))
    socket = assign(socket, form: form)

    if BankPayment.format_version_exists?(
         socket.assigns.current_company.id,
         form["code"],
         form["effective_from"]
       ),
       do: {:noreply, assign(socket, confirm_replace: true, save_errors: [])},
       else: do_save(socket, [])
  end

  @impl true
  def handle_event("replace", _params, socket), do: do_save(socket, replace: true)

  defp do_save(socket, opts) do
    form = socket.assigns.form
    com = socket.assigns.current_company

    with {:ok, spec} <- decode_and_validate(form["spec"]) do
      attrs = %{
        "code" => form["code"],
        "name" => form["name"],
        "effective_from" => form["effective_from"],
        "spec" => spec
      }

      case BankPayment.save_format(attrs, com, socket.assigns.current_user, opts) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             if(opts[:replace],
               do: gettext("File format version replaced."),
               else: gettext("File format saved.")
             )
           )
           |> push_navigate(to: ~p"/companies/#{com.id}/bank_file_formats")}

        {:error, cs} ->
          {:noreply, assign(socket, confirm_replace: false, save_errors: changeset_errors(cs))}

        :not_authorise ->
          {:noreply,
           put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
      end
    else
      {:error, _} ->
        {:noreply,
         assign(socket,
           confirm_replace: false,
           save_errors: [gettext("fix spec errors before saving")]
         )}
    end
  end

  defp decode_and_validate(json) when is_binary(json) do
    with {:ok, spec} <- Jason.decode(json),
         :ok <- BankPayment.validate_spec(spec) do
      {:ok, spec}
    else
      {:error, %Jason.DecodeError{}} -> {:error, gettext("invalid JSON")}
      {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
      {:error, msg} -> {:error, msg}
    end
  end

  defp decode_and_validate(_), do: {:error, gettext("spec is required")}

  defp assign_spec_errors(socket, json) when is_binary(json) do
    errors =
      case Jason.decode(json) do
        {:ok, spec} ->
          case BankPayment.validate_spec(spec) do
            :ok -> []
            {:error, errs} -> errs
          end

        {:error, _} ->
          [gettext("invalid JSON")]
      end

    assign(socket, spec_errors: errors)
  end

  defp assign_spec_errors(socket, _), do: socket

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-9/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-900/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={%{}} id="format-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <div class="grid grid-cols-12 gap-2 mb-2">
          <div class="col-span-4">
            <label class="block text-sm font-medium">{gettext("Template")}</label>
            <select
              name="file_format[template]"
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            >
              <option value="">{gettext("-- choose --")}</option>
              <option :for={t <- @templates} value={t.code} selected={t.code == @form["template"]}>
                {t.name}
              </option>
            </select>
          </div>
          <div class="col-span-2 mt-6">
            <button type="button" id="load-template" phx-click="load_template" class="blue button">{gettext(
              "Load template"
            )}</button>
          </div>
        </div>
        <div class="grid grid-cols-12 gap-2 mb-2">
          <div class="col-span-4">
            <label class="block text-sm font-medium">{gettext("Code")}</label>
            <input
              type="text"
              name="file_format[code]"
              value={@form["code"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-5">
            <label class="block text-sm font-medium">{gettext("Name")}</label>
            <input
              type="text"
              name="file_format[name]"
              value={@form["name"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-3">
            <label class="block text-sm font-medium">{gettext("Effective From")}</label>
            <input
              type="date"
              name="file_format[effective_from]"
              value={@form["effective_from"]}
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
        <p :for={msg <- @spec_errors} class="text-rose-600 dark:text-rose-400 text-sm">{msg}</p>
        <p :for={msg <- @save_errors} class="text-rose-600 dark:text-rose-400 text-sm">{msg}</p>

        <div class="mt-4 border rounded p-3 bg-white dark:bg-gray-800">
          <p class="font-semibold mb-2">{gettext("Preview")}</p>
          <div class="grid grid-cols-12 gap-2">
            <div class="col-span-6">
              <label class="block text-sm font-medium">{gettext("Profile")}</label>
              <select
                name="file_format[profile_id]"
                class="w-full border rounded px-2 py-1 dark:bg-gray-800"
              >
                <option :for={p <- @profiles} value={p.id} selected={p.id == @form["profile_id"]}>
                  {p.account_name}
                </option>
              </select>
            </div>
            <div class="col-span-3 mt-6">
              <button type="button" phx-click="preview" class="blue button">{gettext("Preview")}</button>
            </div>
          </div>
          <p :if={@preview_error} class="text-rose-600 dark:text-rose-400 mt-2">{@preview_error}</p>
          <pre
            :if={@preview_lines}
            class="mt-2 font-mono text-xs overflow-x-auto bg-gray-100 dark:bg-gray-900 p-2 rounded"
          >{Enum.join(@preview_lines, "\n")}</pre>
        </div>

        <div
          :if={@confirm_replace}
          class="mt-4 border rounded border-amber-500 bg-amber-100 dark:bg-amber-900/40 p-3 text-center"
        >
          <p class="font-semibold">
            {gettext("A version of '%{code}' effective %{date} already exists.",
              code: @form["code"],
              date: @form["effective_from"]
            )}
          </p>
          <p class="text-sm mb-2">
            {gettext("Existing batches keep the layout they were made with.")}
          </p>
          <button type="button" phx-click="replace" class="red button" id="replace-version">{gettext(
            "Replace this version"
          )}</button>
        </div>

        <div class="flex justify-center mt-4 gap-2">
          <button type="submit" class="blue button">{gettext("Save")}</button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/bank_file_formats"}
            class="blue button"
          >{gettext("Cancel")}</.link>
        </div>
      </.form>
    </div>
    """
  end
end
