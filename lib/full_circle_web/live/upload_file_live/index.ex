defmodule FullCircleWeb.UploadFileLive.Index do
  use FullCircleWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Upload Files"))
     |> assign(:uploaded_files, uploaded_files(socket))
     |> allow_upload(:any_file, accept: :any, max_file_size: 10_000_000, max_entries: 5)}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :any_file, ref)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", _params, socket) do
    consume_uploaded_entries(socket, :any_file, fn %{path: path}, entry ->
      dest =
        Path.join([
          :code.priv_dir(:full_circle),
          "static",
          "uploads",
          "#{socket.assigns.current_company.id}",
          Path.basename(entry.client_name)
        ])

      # You will need to create `priv/static/uploads` for `File.cp!/2` to work.

      File.cp!(path, dest)

      {:ok, dest}
    end)

    {:noreply, socket |> assign(:uploaded_files, uploaded_files(socket))}
  end

  defp uploaded_files(socket) do
    path =
      Path.join([
        :code.priv_dir(:full_circle),
        "static",
        "uploads",
        "#{socket.assigns.current_company.id}"
      ])

    filenames = File.ls!(path)

    filenames |> Enum.map(fn f -> Map.merge(File.stat!(Path.join(path, f)), %{name: f}) end)
  end

  defp error_to_string(:too_large), do: "Too large!"
  defp error_to_string(:too_many_files), do: "You have selected too many files!"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-10/12 h-screen mx-auto text-center flex gap-2">
      <div class="w-[40%] h-[50%] border-4 rounded bg-yellow-200 border-yellow-800">
        <div class="text-3xl font-medium"><%= @page_title %></div>
        <span class="text font-medium">
          <%= "Maximum file size is #{@uploads.any_file.max_file_size / 1_000_000}MB," %>
        </span>
        <span class="text-xl font-medium">
          <%= "and select only #{@uploads.any_file.max_entries} files." %>
        </span>
        <form id="upload-form" phx-submit="save" phx-change="validate">
          <div class={if Enum.count(@uploads.any_file.entries) == 0, do: "visible", else: "invisible"}>
            <.live_file_input upload={@uploads.any_file} />
          </div>
          <div phx-drop-target={@uploads.any_file.ref}>
            <%= for entry <- @uploads.any_file.entries do %>
              <div class="mt-2 font-medium gap-2 flex flex-row text-center tracking-tighter">
                <div class="w-[50%] text-right"><%= entry.client_name %></div>

                <div class="w-[50%] text-left">
                  <progress class="mt-1" value={entry.progress} max="100">
                    <%= entry.progress %>%
                  </progress>
                  <.link
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                    class="font-bold text-orange-600"
                  >
                    X
                  </.link>
                  <%= for err <- upload_errors(@uploads.any_file, entry) do %>
                    <span class=" text-rose-600">
                      <%= error_to_string(err) %>
                    </span>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= for err <- upload_errors(@uploads.any_file) do %>
              <p class="w-[50%] text-xl mx-auto text-rose-600 border-4 font-bold rounded p-4 border-rose-700 bg-rose-200">
                <%= error_to_string(err) %>
              </p>
            <% end %>
          </div>
          <.button
            :if={
              Enum.count(@uploads.any_file.errors) == 0 and
                Enum.count(@uploads.any_file.entries) > 0
            }
            type="submit"
          >
            Upload
          </.button>
        </form>
      </div>
      <div class="w-[60%] h-[90%] border-4 font-mono rounded bg-green-200 border-green-800 overflow-y-auto">
        <%= for f <- @uploaded_files do %>
          <div class="flex gap-1 m-2 hover:bg-green-400 hover:cursor-pointer">
            <div class="w-[64%] text-left"><%= f.name %></div>
            <div class="w-[10%] text-right"><%= (f.size / 1_000) |> Float.round(2) %>KB</div>
            <div class="w-[24%] text-right">
              <%= f.mtime
              |> :calendar.datetime_to_gregorian_seconds()
              |> DateTime.from_gregorian_seconds()
              |> to_fc_time_format %>
            </div>
            <div class="w-[2%]">
              <.link
                phx-click="cancel-delete-file"
                phx-value={f.name}
                class="font-bold text-orange-600"
              >
                X
              </.link>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
