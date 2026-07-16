defmodule FullCircleWeb.StatutoryCalcLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{HR, StatutoryConfig}

  @impl true
  def mount(params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_statutory_config,
         socket.assigns.current_company
       ) do
      com_id = socket.assigns.current_company.id
      code = params["code"] || ""

      script =
        if code != "" do
          case StatutoryConfig.list_versions(:calc, com_id) |> Enum.find(&(&1.code == code)) do
            nil -> ""
            newest -> newest.script
          end
        else
          ""
        end

      name =
        if code != "" do
          case StatutoryConfig.list_versions(:calc, com_id) |> Enum.find(&(&1.code == code)) do
            nil -> ""
            newest -> newest.name
          end
        else
          ""
        end

      {:ok,
       socket
       |> assign(page_title: gettext("New Calc Version"))
       |> assign(
         form: %{
           "code" => code,
           "name" => name,
           "effective_from" => Date.to_iso8601(Date.utc_today()),
           "script" => script,
           "employee_name" => "",
           "employee_id" => "",
           "pay_month" => "#{Timex.today().month}",
           "pay_year" => "#{Timex.today().year}"
         }
       )
       |> assign(preview: nil)
       |> assign(preview_error: nil)
       |> assign(save_errors: [])
       |> assign(confirm_replace: false)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["calc", "employee_name"], "calc" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "employee_name",
        "employee_id",
        &HR.get_employee_by_name/3
      )

    {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params))}
  end

  @impl true
  def handle_event("validate", %{"calc" => params}, socket) do
    {:noreply,
     socket
     |> assign(form: Map.merge(socket.assigns.form, params))
     |> assign(confirm_replace: false)}
  end

  @impl true
  def handle_event("preview", params, socket) do
    form = Map.merge(socket.assigns.form, Map.get(params, "calc", %{}))
    socket = assign(socket, form: form)

    with emp_id when emp_id not in [nil, ""] <- form["employee_id"],
         {:ok, emp} <- fetch_employee(emp_id, socket),
         month <- String.to_integer(form["pay_month"]),
         year <- String.to_integer(form["pay_year"]),
         {:ok, new_val} <-
           StatutoryConfig.preview_calc(form["script"], form["code"], emp, month, year) do
      current = StatutoryConfig.current_value(form["code"], emp, month, year)

      {:noreply,
       socket
       |> assign(preview: %{new: new_val, current: current})
       |> assign(preview_error: nil)}
    else
      {:error, msg} ->
        {:noreply, socket |> assign(preview: nil) |> assign(preview_error: msg)}

      _ ->
        {:noreply,
         socket
         |> assign(preview: nil)
         |> assign(preview_error: gettext("select an employee to preview"))}
    end
  end

  @impl true
  def handle_event("save", %{"calc" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    socket = assign(socket, form: form)

    if StatutoryConfig.version_exists?(
         :calc,
         socket.assigns.current_company.id,
         form["code"],
         form["effective_from"]
       ) do
      {:noreply, assign(socket, confirm_replace: true, save_errors: [])}
    else
      do_save(socket, [])
    end
  end

  @impl true
  def handle_event("replace", _params, socket) do
    do_save(socket, replace: true)
  end

  defp do_save(socket, opts) do
    form = socket.assigns.form

    attrs = %{
      code: form["code"],
      name: form["name"],
      effective_from: form["effective_from"],
      script: form["script"]
    }

    case StatutoryConfig.save_calc(
           attrs,
           socket.assigns.current_company,
           socket.assigns.current_user,
           opts
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(opts[:replace], do: gettext("Calc version replaced."), else: gettext("Calc saved."))
         )
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/statutory_calcs")}

      {:error, cs} ->
        {:noreply,
         socket
         |> assign(confirm_replace: false)
         |> assign(save_errors: save_error_messages(cs))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save_error_messages(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, msgs} ->
      Enum.map(msgs, fn msg -> if field == :script, do: msg, else: "#{field}: #{msg}" end)
    end)
  end

  defp fetch_employee(id, socket) do
    {:ok, HR.get_employee!(id, socket.assigns.current_company, socket.assigns.current_user)}
  rescue
    Ecto.NoResultsError -> {:error, gettext("employee not found")}
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
              name="calc[code]"
              value={@form["code"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-3">
            <label class="block text-sm font-medium">{gettext("Name")}</label>
            <input
              type="text"
              name="calc[name]"
              value={@form["name"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-3">
            <label class="block text-sm font-medium">{gettext("Effective From")}</label>
            <input
              type="date"
              name="calc[effective_from]"
              value={@form["effective_from"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
        </div>

        <label class="block text-sm font-medium">{gettext("Script")}</label>
        <textarea
          name="calc[script]"
          rows="18"
          class="w-full font-mono text-sm border rounded px-2 py-1 dark:bg-gray-800"
        >{@form["script"]}</textarea>
        <p :for={msg <- @save_errors} class="text-rose-600 text-sm">{msg}</p>

        <div class="mt-4 border rounded p-3 bg-white dark:bg-gray-800">
          <p class="font-semibold mb-2">{gettext("Preview")}</p>
          <div class="grid grid-cols-12 gap-2">
            <div class="col-span-5">
              <input type="hidden" name="calc[employee_id]" value={@form["employee_id"]} />
              <label class="block text-sm font-medium">{gettext("Employee")}</label>
              <input
                type="search"
                id="calc_employee_name"
                name="calc[employee_name]"
                value={@form["employee_name"]}
                phx-hook="tributeAutoComplete"
                url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
                class="w-full border rounded px-2 py-1 dark:bg-gray-800"
              />
            </div>
            <div class="col-span-2">
              <label class="block text-sm font-medium">{gettext("Month")}</label>
              <input
                type="number"
                name="calc[pay_month]"
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
                name="calc[pay_year]"
                value={@form["pay_year"]}
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
          <p :if={@preview} class="mt-2 font-mono">
            {gettext("New:")} {Decimal.to_string(@preview.new)}
            <%= if @preview.current do %>
              / {gettext("Current:")} {Decimal.to_string(@preview.current)}
            <% end %>
          </p>
        </div>

        <div
          :if={@confirm_replace}
          class="mt-4 border rounded border-amber-500 bg-amber-100 dark:bg-amber-900/40 p-3 text-center"
        >
          <p class="font-semibold">
            {gettext(
              "A version of '%{code}' effective %{date} already exists.",
              code: @form["code"],
              date: @form["effective_from"]
            )}
          </p>
          <p class="text-sm mb-2">
            {gettext(
              "Replace it to correct a mistake in place, or change the effective date to keep history."
            )}
          </p>
          <button type="button" phx-click="replace" class="red button" id="replace-version">
            {gettext("Replace this version")}
          </button>
        </div>

        <div class="flex justify-center mt-4 gap-2">
          <button type="submit" class="blue button">{gettext("Save")}</button>
          <.link navigate={~p"/companies/#{@current_company.id}/statutory_calcs"} class="blue button">
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
