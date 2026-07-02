defmodule FullCircleWeb.StatutoryBundleLive.Import do
  use FullCircleWeb, :live_view

  alias FullCircle.StatutoryConfig

  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :manage_statutory_config,
         socket.assigns.current_company
       ) do
      {:ok,
       socket
       |> assign(page_title: gettext("Import Statutory Bundle"))
       |> assign(step: :upload)
       |> assign(bundle: nil)
       |> assign(diff: [])
       |> assign(validation_errors: [])
       |> assign(decode_error: nil)
       |> allow_upload(:bundle,
         accept: ~w(.json),
         max_entries: 1,
         max_file_size: 10_000_000,
         auto_upload: true,
         progress: &handle_bundle_progress/3
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  defp handle_bundle_progress(:bundle, entry, socket) do
    if entry.done? do
      case consume_bundle(socket) do
        {:ok, bundle} ->
          case StatutoryConfig.validate_bundle(bundle) do
            :ok ->
              diff = StatutoryConfig.bundle_diff(bundle, socket.assigns.current_company.id)

              {:noreply,
               socket
               |> assign(step: :diff)
               |> assign(bundle: bundle)
               |> assign(diff: diff)
               |> assign(validation_errors: [])
               |> assign(decode_error: nil)}

            {:error, errors} ->
              {:noreply,
               socket
               |> assign(step: :upload)
               |> assign(bundle: nil)
               |> assign(diff: [])
               |> assign(validation_errors: errors)
               |> assign(decode_error: nil)}
          end

        {:error, msg} ->
          {:noreply,
           socket
           |> assign(step: :upload)
           |> assign(decode_error: msg)
           |> assign(validation_errors: [])}
      end
    else
      {:noreply, socket}
    end
  end

  defp consume_bundle(socket) do
    uploaded =
      consume_uploaded_entries(socket, :bundle, fn %{path: path}, _entry ->
        path |> File.read!() |> then(&{:ok, &1})
      end)

    case uploaded do
      [binary] ->
        case Jason.decode(binary) do
          {:ok, map} -> {:ok, map}
          {:error, _} -> {:error, gettext("invalid JSON")}
        end

      _ ->
        {:error, gettext("please upload a JSON bundle")}
    end
  end

  @impl true
  def handle_event("apply", _params, socket) do
    case StatutoryConfig.import_bundle(
           socket.assigns.bundle,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, counts} ->
        {:noreply,
         socket
         |> assign(step: :applied)
         |> put_flash(
           :info,
           gettext(
             "Imported %{tables} tables, %{calcs} calcs, %{formats} file formats.",
             tables: counts.rate_tables,
             calcs: counts.calcs,
             formats: counts.file_formats
           )
         )}

      {:error, errors} ->
        {:noreply, assign(socket, validation_errors: errors)}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp all_unchanged?(diff), do: diff != [] and Enum.all?(diff, &(&1.status == :unchanged))

  defp status_class(:new), do: "bg-green-200 text-green-800"
  defp status_class(:replaces), do: "bg-amber-200 text-amber-800"
  defp status_class(:unchanged), do: "bg-gray-200 text-gray-700"

  defp kind_label(:table), do: gettext("table")
  defp kind_label(:calc), do: gettext("calc")
  defp kind_label(:file_format), do: gettext("file format")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-900/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <div :if={@step == :upload} class="text-center my-4">
        <form id="bundle-upload-form">
          <.live_file_input upload={@uploads.bundle} />
        </form>
        <p :if={@decode_error} class="text-rose-600 font-semibold mt-2">{@decode_error}</p>
        <ul :if={@validation_errors != []} class="text-rose-600 text-left mt-2 list-disc pl-6">
          <li :for={err <- @validation_errors}>{err}</li>
        </ul>
      </div>

      <div :if={@step == :diff} class="mt-4">
        <table class="w-full text-sm border border-gray-400">
          <thead class="bg-gray-200 dark:bg-gray-700">
            <tr>
              <th class="border px-2 py-1">{gettext("Kind")}</th>
              <th class="border px-2 py-1">{gettext("Code")}</th>
              <th class="border px-2 py-1">{gettext("Effective From")}</th>
              <th class="border px-2 py-1">{gettext("Status")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @diff}>
              <td class="border px-2 py-1 text-center">{kind_label(row.kind)}</td>
              <td class="border px-2 py-1 text-center font-mono">{row.code}</td>
              <td class="border px-2 py-1 text-center">{row.effective_from}</td>
              <td class="border px-2 py-1 text-center">
                <span class={"px-2 py-0.5 rounded font-semibold #{status_class(row.status)}"}>
                  {row.status}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
        <div class="flex justify-center mt-4 gap-2">
          <button
            type="button"
            phx-click="apply"
            disabled={all_unchanged?(@diff)}
            class="blue button disabled:opacity-50"
          >
            {gettext("Apply")}
          </button>
        </div>
      </div>

      <div :if={@step == :applied} class="text-center mt-4">
        <.link navigate={~p"/companies/#{@current_company.id}/statutory_calcs"} class="blue button">
          {gettext("Back to Calcs")}
        </.link>
      </div>
    </div>
    """
  end
end