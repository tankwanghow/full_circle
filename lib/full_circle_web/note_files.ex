defmodule FullCircleWeb.NoteFiles do
  @moduledoc """
  Delivers "a file landed" (`{:note_files_changed, target}` on
  `Attachments.topic/1`) to whatever on the page shows that target's files —
  a write box's tray, a notes panel's posts, the note page — so no host
  LiveView needs a handle_info for it. Components register with `listen/3`
  from `update/2`; registrations live in the LiveView process's dictionary
  (components share their LiveView's process), keyed by target. A stale
  registration (component gone) is harmless: send_update to a missing
  component is ignored. Every broadcast is halted here.
  """
  alias FullCircle.Notes.Attachments

  @key {__MODULE__, :listeners}

  def on_mount(:route, _params, _session, socket) do
    company = socket.assigns[:current_company]

    if company && Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(FullCircle.PubSub, Attachments.topic(company.id))
      {:cont, Phoenix.LiveView.attach_hook(socket, :note_files, :handle_info, &route/2)}
    else
      {:cont, socket}
    end
  end

  def listen(target, module, id), do: put(target, {module, id})

  def listen_self(target), do: put(target, :self)

  @doc "A QR modal for `target` closes when that phone session ends."
  def listen_phone(target, module, id), do: put({:phone, target}, {module, id})

  defp put(target, who) do
    listeners = Process.get(@key, %{})
    Process.put(@key, Map.update(listeners, target, MapSet.new([who]), &MapSet.put(&1, who)))
    :ok
  end

  defp route({:note_files_changed, target}, socket) do
    for who <- Map.get(Process.get(@key, %{}), target, []) do
      case who do
        :self -> send(self(), {:note_files, target})
        {module, id} -> Phoenix.LiveView.send_update(module, id: id, note_files: target)
      end
    end

    {:halt, socket}
  end

  # The phone pressed ✓ Close: the QR modal showing that target closes.
  # Its listeners are keyed {:phone, target}, apart from the file listeners,
  # so a box or panel never gets an update it has no clause for.
  defp route({:phone_closed, target}, socket) do
    for {module, id} <- Map.get(Process.get(@key, %{}), {:phone, target}, []) do
      Phoenix.LiveView.send_update(module, id: id, phone_closed: true)
    end

    {:halt, socket}
  end

  defp route(_msg, socket), do: {:cont, socket}
end
