defmodule FullCircleWeb.ReportLive.EAForm do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("EA Form"))
      |> allow_upload(:csv_file,
        accept: ~w(.csv),
        max_file_size: 1_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> assign_async(:result, fn ->
        {:ok,
         %{
           result: {[], []}
         }}
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :csv_file, ref)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_progress(:csv_file, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, csv_to_attrs(path)}
        end)

      {:noreply, socket |> assign_async(:result, fn -> {:ok, %{result: result}} end)}
    else
      {:noreply, socket}
    end
  end

  defp error_to_string(:too_large), do: "Too large!"
  defp error_to_string(:too_many_files), do: "You have selected too many files!"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  defp csv_to_attrs(path) do
    k =
      File.stream!(path)
      |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
      |> Enum.to_list()

    {Enum.at(k, 0), Enum.drop(k, 1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-10/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={%{}}
        id="object-form"
        autocomplete="off"
        phx-submit="upload"
        phx-change="validate"
        class="p-4 mb-1 border rounded-lg border-blue-500 bg-blue-200"
      >
        {"Maximum file size is #{@uploads.csv_file.max_file_size / 1_000_000} MB"}

        <.live_file_input upload={@uploads.csv_file} />
        <div phx-drop-target={@uploads.csv_file.ref} class="p-2">
          <%= for entry <- @uploads.csv_file.entries do %>
            <div class="mt-2 gap-2 flex flex-row tracking-tighter border-2 border-green-600 place-items-center p-2 rounded-lg">
              <div class="w-[40%]">{entry.client_name}</div>
              <div class="w-[10%] border">
                {DateTime.from_unix!(entry.client_last_modified, :millisecond)
                |> FullCircleWeb.Helpers.format_datetime(@current_company)}
              </div>
              <div class="w-[50%] text-right">
                <progress class="mt-1" value={entry.progress} max="100">
                  {entry.progress}
                </progress>
                <.link
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="font-bold text-orange-600"
                >
                  X
                </.link>
                <%= for err <- upload_errors(@uploads.csv_file, entry) do %>
                  <div class="text-center text-rose-600">
                    {error_to_string(err)}
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= for err <- upload_errors(@uploads.csv_file) do %>
            <p class="w-[50%] mx-auto text-rose-600 border-4 font-bold rounded p-4 border-rose-700 bg-rose-200">
              {error_to_string(err)}
            </p>
          <% end %>
        </div>
      </.form>

      <.async_html result={@result}>
        <:result_html>
          <% {col, row} = @result.result %>
          <div :if={Enum.count(col) > 0} class="flex flex-row">
          <div class="w-[1.5%] text-center font-bold border rounded bg-gray-200 border-gray-500"></div>
            <%= for h <- col do %>
              <div class="w-[4.7%] text-center font-bold border rounded bg-gray-200 border-gray-500">
                {h}
              </div>
            <% end %>
          </div>

          <%= for r <- row do %>
            <div class="flex flex-row h-20 overflow-hidden hover:bg-blue-200 bg-blue-100">
              <.link
                target="_blank"
                href={~p"/companies/#{@current_company.id}/eaform/print?data=#{Enum.join(r, "|")}"}
              >
                <.icon name="hero-printer-solid" class="h-5 w-5" />
              </.link>
              <%= for c <- r do %>
                <div class="w-[4.7%] text-center border overflow-hidden rounded border-blue-200">
                  {c}
                </div>
              <% end %>
            </div>
          <% end %>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
