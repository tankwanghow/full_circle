defmodule FullCircleWeb.StatutoryRateTableLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.StatutoryConfig

  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_statutory_config,
         socket.assigns.current_company
       ) do
      com_id = socket.assigns.current_company.id

      existing_codes =
        StatutoryConfig.list_versions(:table, com_id)
        |> Enum.map(& &1.code)
        |> Enum.uniq()

      {:ok,
       socket
       |> assign(page_title: gettext("New Rate Table Version"))
       |> assign(form: %{"code" => "", "effective_from" => Date.to_iso8601(Date.utc_today())})
       |> assign(preview: nil)
       |> assign(csv_error: nil)
       |> assign(existing_codes: existing_codes)
       |> allow_upload(:csv,
         accept: ~w(.csv .txt),
         max_entries: 1,
         max_file_size: 2_000_000,
         auto_upload: true,
         progress: &handle_csv_progress/3
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  defp handle_csv_progress(:csv, entry, socket) do
    if entry.done? do
      case consume_upload(socket) do
        {:ok, parsed} ->
          {:noreply, socket |> assign(preview: parsed) |> assign(csv_error: nil)}

        {:error, msg} ->
          {:noreply, socket |> assign(preview: nil) |> assign(csv_error: msg)}
      end
    else
      {:noreply, socket}
    end
  end

  defp consume_upload(socket) do
    uploaded =
      consume_uploaded_entries(socket, :csv, fn %{path: path}, _entry ->
        path |> File.read!() |> then(&{:ok, &1})
      end)

    case uploaded do
      [binary] -> StatutoryConfig.parse_table_csv(binary)
      _ -> {:error, gettext("please upload a CSV file")}
    end
  end

  @impl true
  def handle_event("validate", %{"rate_table" => params}, socket) do
    {:noreply, assign(socket, form: params)}
  end

  @impl true
  def handle_event("save", %{"rate_table" => params}, socket) do
    preview = socket.assigns.preview

    cond do
      is_nil(preview) ->
        {:noreply, assign(socket, csv_error: gettext("please upload a valid CSV file"))}

      true ->
        attrs = %{
          code: params["code"],
          effective_from: params["effective_from"],
          columns: preview.columns,
          rows: preview.rows
        }

        case StatutoryConfig.save_rate_table(
               attrs,
               socket.assigns.current_company,
               socket.assigns.current_user
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Rate table saved."))
             |> push_navigate(
               to: ~p"/companies/#{socket.assigns.current_company.id}/statutory_rate_tables"
             )}

          {:error, cs} ->
            {:noreply,
             socket
             |> assign(form: params)
             |> put_flash(:error, list_errors_to_string(cs.errors))}

          :not_authorise ->
            {:noreply,
             put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
        end
    end
  end

  defp preview_rows(rows) do
    n = length(rows)

    cond do
      n <= 17 -> rows
      true -> Enum.take(rows, 15) ++ [nil] ++ Enum.take(rows, -2)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-900/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={%{}}
        id="object-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-4">
            <label class="block text-sm font-medium">{gettext("Code")}</label>
            <input
              type="text"
              name="rate_table[code]"
              value={@form["code"]}
              list="rate-table-codes"
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
            <datalist id="rate-table-codes">
              <option :for={c <- @existing_codes} value={c} />
            </datalist>
          </div>
          <div class="col-span-4">
            <label class="block text-sm font-medium">{gettext("Effective From")}</label>
            <input
              type="date"
              name="rate_table[effective_from]"
              value={@form["effective_from"]}
              class="w-full border rounded px-2 py-1 dark:bg-gray-800"
            />
          </div>
          <div class="col-span-4 mt-6">
            <.live_file_input upload={@uploads.csv} />
          </div>
        </div>

        <p :if={@csv_error} class="text-rose-600 font-semibold mt-2">{@csv_error}</p>
        <span :for={{_, msg} <- @uploads.csv.errors} class="text-rose-600">{msg}</span>

        <div :if={@preview} class="mt-4 overflow-x-auto">
          <p class="font-semibold mb-1">
            {gettext("Preview (%{count} rows)", count: length(@preview.rows))}
          </p>
          <table class="w-full text-sm border border-gray-400">
            <thead class="bg-gray-200 dark:bg-gray-700">
              <tr>
                <th :for={col <- @preview.columns} class="border px-2 py-1">{col}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- preview_rows(@preview.rows)}>
                <td
                  :for={cell <- row}
                  :if={row}
                  class="border px-2 py-1 text-center font-mono"
                >
                  {cell}
                </td>
                <td
                  :if={is_nil(row)}
                  colspan={length(@preview.columns)}
                  class="border px-2 py-1 text-center"
                >
                  …
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="flex justify-center mt-4">
          <button type="submit" class="blue button">{gettext("Save")}</button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/statutory_rate_tables"}
            class="blue button ml-2"
          >
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
