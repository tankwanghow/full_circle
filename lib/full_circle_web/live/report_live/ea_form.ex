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
    <div class="w-11/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={%{}}
        id="object-form"
        autocomplete="off"
        phx-submit="upload"
        phx-change="validate"
        class="p-4 mb-1 border rounded-lg border-blue-500 bg-yellow-200"
      >
        <span class="font-bold text-xl">
          {"Maximum file size is #{@uploads.csv_file.max_file_size / 1_000_000} MB, file type CSV"}
          <.live_file_input upload={@uploads.csv_file} />
        </span>

        <div class="font-medium">
          Your EA Data file needed the columns below, please refer
          <a
            href="/samples/ea_cp8a_pin2023.pdf"
            download="ea_cp8a_pin2023.pdf"
            class="text-red-400 hover:text-red-700 hover:font-bold"
          >
            C.P.8A - Pin 2023
          </a>
        </div>
        <div class="font-mono">
          <p>
            <span class="font-bold text-green-700">HEADER - </span>nosiri, nomajikanE, year, tin, lhdnbrh
          </p>
          <p>
            <span class="font-bold text-green-700">SECTION A - </span>a1, a2, a3, a4, a5, a6, a7, a8, a9a, a9b
          </p>
          <p>
            <span class="font-bold text-green-700">SECTION B - </span>b1a, b1b, b1cname, b1c, b1d, b1e, b1fdari, b1fhingga, b1f, b2a, b2b, b2, b3nyata, b3, b4alamat, b4, b5, b6
          </p>
          <p><span class="font-bold text-green-700">SECTION C - </span>c1, c2, jumlah</p>
          <p>
            <span class="font-bold text-green-700">SECTION D - </span>d1, d2, d3, d4, d5a, d5b, d6
          </p>
          <p><span class="font-bold text-green-700">SECTION E - </span>e1name, e1, e2</p>
          <p><span class="font-bold text-green-700">SECTION F - </span>f</p>
          <p>
            <span class="font-bold text-green-700">FOOTER - </span>tarikh, nama, pos, address, phone
          </p>
        </div>
        <a
          href="/samples/ea_data_format.csv"
          download="ea_data_format.csv"
          class="text-red-400 hover:text-red-700 hover:font-bold"
        >
          Download Sample CSV File
        </a>
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
            <div class="text-center font-bold border rounded bg-gray-200 border-gray-500"></div>
            <%= for h <- col do %>
              <div class="max-w-60 text-center font-bold border rounded bg-gray-200 border-gray-500">
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
                <div class="max-w-60 text-center border overflow-hidden rounded border-blue-200">
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
