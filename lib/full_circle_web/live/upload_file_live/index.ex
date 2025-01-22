defmodule FullCircleWeb.UploadFileLive.Index do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    root =
      Path.join([
        Application.get_env(:full_circle, :uploads_dir),
        "#{socket.assigns.current_company.id}"
      ])

    socket =
      socket
      |> assign(:mark_delete, nil)
      |> assign(:mark_rename, nil)
      |> assign(:mark_create, nil)
      |> assign(:selected, [])
      |> assign(:root, root)
      |> assign(:current_path, root)
      |> assign(:name_paths, name_paths(root, root))

    {:ok,
     socket
     |> assign(page_title: gettext("Upload Files"))
     |> assign(:uploaded_files, list_files(root))
     |> allow_upload(:any_file, accept: :any, max_file_size: 10_000_000, max_entries: 10)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :any_file, ref)}
  end

  @impl true
  def handle_event("mark-delete", %{"name" => name}, socket) do
    {:noreply, socket |> assign(:mark_delete, name)}
  end

  @impl true
  def handle_event("mark-create", _, socket) do
    {:noreply, socket |> assign(:mark_create, true)}
  end

  @impl true
  def handle_event("clear-mark", _, socket) do
    {:noreply, socket |> clear_all_marked()}
  end

  @impl true
  def handle_event("rename-blur", %{"value" => new, "old-name" => old}, socket) do
    rename(old, new, socket.assigns.current_path)

    {:noreply,
     socket
     |> clear_all_marked()
     |> assign(:uploaded_files, list_files(socket.assigns.current_path))}
  end

  @impl true
  def handle_event("create-folder-blur", %{"value" => new}, socket) do
    create_folder(new, socket.assigns.current_path)

    {:noreply,
     socket
     |> clear_all_marked()
     |> assign(:uploaded_files, list_files(socket.assigns.current_path))}
  end

  @impl true
  def handle_event("mark-rename", %{"name" => name}, socket) do
    {:noreply, socket |> assign(:mark_rename, name)}
  end

  @impl true
  def handle_event("delete-file", %{"filename" => filename}, socket) do
    path =
      Path.join([
        socket.assigns.current_path,
        filename
      ])

    File.rm!(path)

    {:noreply,
     socket
     |> clear_all_marked
     |> assign(:uploaded_files, list_files(socket.assigns.current_path))}
  end

  @impl true
  def handle_event("delete-dir", %{"dirname" => dir}, socket) do
    path =
      Path.join([
        socket.assigns.current_path,
        dir
      ])

    File.rm_rf!(path)

    {:noreply,
     socket
     |> clear_all_marked
     |> assign(:uploaded_files, list_files(socket.assigns.current_path))}
  end

  @impl true
  def handle_event("move", _, socket) do
    Enum.each(socket.assigns.selected, fn src ->
      name = Path.split(src) |> Enum.reverse() |> Enum.at(0)
      dest = Path.join(socket.assigns.current_path, name)

      File.rename!(src, dest)
    end)

    {:noreply,
     socket
     |> clear_all_marked
     |> assign(:uploaded_files, list_files(socket.assigns.current_path))}
  end

  @impl true
  def handle_event("upload", _params, socket) do
    consume_uploaded_entries(socket, :any_file, fn %{path: path}, entry ->
      dest =
        Path.join([
          socket.assigns.current_path,
          Path.basename(entry.client_name)
        ])

      File.cp!(path, dest)

      {:ok, dest}
    end)

    {:noreply,
     socket
     |> clear_all_marked
     |> assign(:uploaded_files, list_files(socket.assigns.current_path))}
  end

  @impl true
  def handle_event("cd-down", %{"dirname" => dirname}, socket) do
    path = Path.join([socket.assigns.current_path, dirname])

    if is_nil(Enum.find(socket.assigns.selected, fn x -> x == path end)) do
      socket = socket |> assign(:current_path, path)

      {:noreply,
       socket
       |> assign(:name_paths, name_paths(path, socket.assigns.root))
       |> assign(:uploaded_files, list_files(path))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cd-up", _, socket) do
    path = Path.split(socket.assigns.current_path) |> Enum.drop(-1) |> Path.join()
    socket = socket |> assign(:current_path, path)

    {:noreply,
     socket
     |> assign(:name_paths, name_paths(path, socket.assigns.root))
     |> assign(:uploaded_files, list_files(path))}
  end

  @impl true
  def handle_event("cd-to", %{"path" => path}, socket) do
    socket = socket |> assign(:current_path, path)

    {:noreply,
     socket
     |> assign(:name_paths, name_paths(path, socket.assigns.root))
     |> assign(:uploaded_files, list_files(path))}
  end

  @impl true
  def handle_event("select-clicked", %{"name" => name}, socket) do
    selected =
      if is_nil(Enum.find(socket.assigns.selected, fn x -> x == name end)) do
        [name | socket.assigns.selected]
      else
        Enum.reject(socket.assigns.selected, fn x -> x == name end)
      end

    {:noreply, socket |> assign(:selected, selected)}
  end

  defp rename(old, new, current_path) do
    if String.trim(new) != "" do
      old_path =
        Path.join([
          current_path,
          old
        ])

      new_path =
        Path.join([
          current_path,
          new
        ])

      File.rename!(old_path, new_path)
    end
  end

  defp clear_all_marked(socket) do
    socket
    |> assign(:mark_rename, nil)
    |> assign(:mark_delete, nil)
    |> assign(:mark_create, nil)
    |> assign(:selected, [])
  end

  defp create_folder(new, current_path) do
    if String.trim(new) != "" do
      new_path =
        Path.join([
          current_path,
          new
        ])

      File.mkdir!(new_path)
    end
  end

  defp list_files(path) do
    filenames = File.ls!(path)

    filenames
    |> Enum.map(fn f -> Map.merge(File.stat!(Path.join(path, f)), %{name: f, path: path}) end)
    |> Enum.sort_by(&Atom.to_string(&1.type))
  end

  defp name_paths(path, root) do
    path = String.replace(path, root, "")
    list = Path.split(path)
    list_n = 1..Enum.count(list)
    combine = Enum.zip(list, list_n)

    h =
      for {k, n} <- combine, into: %{} do
        {k, root <> (Enum.slice(list, 0..(n - 1)) |> Path.join())}
      end

    Map.merge(h, %{"root" => root})
  end

  defp error_to_string(:too_large), do: "Too large!"
  defp error_to_string(:too_many_files), do: "You have selected too many files!"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex mx-auto w-10/12 h-screen text-center">
      <div class="w-[40%] h-[90%] mr-4 border-4 rounded bg-yellow-200 border-yellow-800 mb-2 overflow-y-auto">
        <div class="text-3xl font-medium">{@page_title}</div>
        <span class="text font-medium">
          {"Maximum file size is #{@uploads.any_file.max_file_size / 1000_000}MB,"}
        </span>
        <span class="text-xl font-medium">
          {"and select only #{@uploads.any_file.max_entries} files."}
        </span>
        <form id="upload-form" phx-submit="upload" phx-change="validate">
          <div>
            <.live_file_input upload={@uploads.any_file} />
          </div>
          <div phx-drop-target={@uploads.any_file.ref} class="p-2">
            <%= for entry <- @uploads.any_file.entries do %>
              <div class="mt-2 gap-2 flex flex-row tracking-tighter border-2 border-green-600 place-items-center p-2 rounded-lg">
                <div class="w-[50%]">{entry.client_name}</div>
                <div class="w-[50%] text-right">
                  <progress class="mt-1" value={entry.progress} max="100">
                    {entry.progress}%
                  </progress>
                  <.link
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                    class="font-bold text-orange-600"
                  >
                    X
                  </.link>
                  <%= for err <- upload_errors(@uploads.any_file, entry) do %>
                    <div class="text-center text-rose-600">
                      {error_to_string(err)}
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= for err <- upload_errors(@uploads.any_file) do %>
              <p class="w-[40%] text-xl mx-auto text-rose-600 border-4 font-bold rounded p-4 border-rose-700 bg-rose-200">
                {error_to_string(err)}
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

      <div class="w-[60%] h-[90%] border-4 rounded bg-green-200 border-green-800 overflow-y-auto">
        <%= for path <- Path.split(String.replace(@current_path, @root, "root")) do %>
          <%= if @current_path != @name_paths[path] do %>
            <.link class="text-blue-600" phx-click="cd-to" phx-value-path={@name_paths[path]}>
              {path}
            </.link>
          <% else %>
            {path}
          <% end %>/
        <% end %>

        <.link
          :if={is_nil(@mark_delete) and is_nil(@mark_rename) and is_nil(@mark_create)}
          phx-click="mark-create"
          class="font-bold"
        >
          <.icon name="hero-folder-plus-solid" class="h-5 w-5 text-orange-600" />
        </.link>

        <div :if={@mark_create} class="flex ml-4">
          <input
            id="new_folder"
            name="new_folder"
            class="w-[80%] rounded p-1 border border-black"
            phx-blur="create-folder-blur"
          />
          <.link phx-click="clear-mark" class="font-bold text-orange-600">
            <.icon name="hero-no-symbol-solid" class="h-5 w-5" />
          </.link>
        </div>

        <div class="flex place-content-center">
          <%= if Enum.count(@selected) > 0 do %>
            {"Move the selected #{Enum.count(@selected)} file(s) or folder(s) to"}
            <div class="pl-1 hover:cursor-pointer text-rose-600 hover:font-extrabold" phx-click="move">
              Here
            </div>
          <% else %>
            <br />
          <% end %>
        </div>

        <div :if={@current_path != @root} class="flex place-items-center">
          <div class="w-[3%]"></div>
          <.link class="w-[95%] text-left hover:cursor-pointer hover:bg-green-400" phx-click="cd-up">
            <.icon name="hero-folder-minus-solid" class="h-5 w-5 text-orange-600" />..
          </.link>
        </div>

        <%= for f <- @uploaded_files do %>
          <div class="flex mb-1 place-items-center hover:bg-green-400">
            <div
              class="w-[3%]"
              phx-value-name={Path.join([@current_path, f.name])}
              phx-click="select-clicked"
            >
              <%= if is_nil(@mark_delete) and is_nil(@mark_rename) and is_nil(@mark_create) do %>
                <.icon
                  :if={
                    !is_nil(Enum.find(@selected, fn x -> x == Path.join([@current_path, f.name]) end))
                  }
                  name="hero-check-circle-solid"
                />
                <.icon
                  :if={
                    is_nil(Enum.find(@selected, fn x -> x == Path.join([@current_path, f.name]) end))
                  }
                  name="hero-minus-circle"
                />
              <% end %>
            </div>
            <.link
              :if={f.type == :regular and @mark_rename != f.name}
              class="w-[62%] text-left hover:cursor-pointer"
              navigate={
                ~p"/companies/#{@current_company.id}/download/#{Path.join([@current_path, f.name])}"
              }
              target="_blank"
            >
              <.icon name="hero-document-solid" class="h-5 w-5 text-cyan-600" />
              {f.name}
            </.link>

            <.link
              :if={f.type == :directory and @mark_rename != f.name}
              class="w-[62%] text-left hover:cursor-pointer text-blue-600"
              phx-click="cd-down"
              phx-value-dirname={f.name}
            >
              <.icon name="hero-folder-solid" class="h-5 w-5 text-orange-600" />
              {f.name}
            </.link>

            <div :if={@mark_rename == f.name} class="w-[62%] p-1">
              <div class="flex">
                <input
                  id="rename"
                  name="rename"
                  value={f.name}
                  phx-value-old-name={f.name}
                  class="rounded p-1 w-full"
                  phx-blur="rename-blur"
                />
                <.link phx-click="clear-mark" class="font-bold text-orange-600">
                  <.icon name="hero-no-symbol-solid" class="h-5 w-5" />
                </.link>
              </div>
            </div>

            <div :if={@mark_delete == f.name and f.type == :regular} class="w-[32%] text-right italic">
              <.link
                phx-click="delete-file"
                phx-value-filename={f.name}
                class="font-bold text-orange-600"
              >
                <.icon name="hero-trash-solid" class="h-5 w-5" />
              </.link>
              {"<-- click to confirm delete file"}
              <.link phx-click="clear-mark" class="font-bold text-orange-600">
                <.icon name="hero-no-symbol-solid" class="h-5 w-5" />
              </.link>
            </div>

            <div
              :if={@mark_delete == f.name and f.type == :directory}
              class="w-[32%] text-right italic"
            >
              <.link
                phx-click="delete-dir"
                phx-value-dirname={f.name}
                class="font-bold text-orange-600"
              >
                <.icon name="hero-trash-solid" class="h-5 w-5" />
              </.link>
              {"<-- click to confirm delete folder"}
              <.link phx-click="clear-mark" class="font-bold text-orange-600">
                <.icon name="hero-no-symbol-solid" class="h-5 w-5" />
              </.link>
            </div>

            <div class="w-[3%]">
              <.link
                :if={is_nil(@mark_delete) and is_nil(@mark_rename) and is_nil(@mark_create)}
                phx-click={JS.push("mark-rename")}
                phx-value-name={f.name}
                class="font-bold text-blue-600"
              >
                <.icon name="hero-pencil-square-solid" class="h-5 w-5" />
              </.link>
            </div>

            <div :if={@mark_delete != f.name} class="w-[19%] text-right">
              {f.ctime
              |> :calendar.datetime_to_gregorian_seconds()
              |> DateTime.from_gregorian_seconds()
              |> to_fc_time_format(@current_company, :datetime)}
            </div>

            <div :if={@mark_delete != f.name} class="w-[10%] text-right">
              {(f.size / 1_000) |> Float.round(2)}KB
            </div>

            <div class="w-[3%]">
              <.link
                :if={is_nil(@mark_delete) and is_nil(@mark_rename) and is_nil(@mark_create)}
                phx-click="mark-delete"
                phx-value-name={f.name}
                class="font-bold text-green-600"
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
