defmodule FullCircleWeb.NoteLive.PhoneQrComponent do
  @moduledoc """
  "📱 From phone": a QR code for the phone upload page (`/up/:token`) of one
  write-box tray or one saved note. The token is made when the QR is opened
  (10-minute idle window, `FullCircleWeb.PhoneUpload`); opening it for a tray
  creates the tray row so the phone can fill it before any desktop upload.
  """
  use FullCircleWeb, :live_component

  alias FullCircle.Notes.Trays
  alias FullCircleWeb.PhoneUpload

  @impl true
  def update(assigns, socket),
    do: {:ok, socket |> assign(assigns) |> assign_new(:qr, fn -> nil end)}

  @impl true
  def handle_event("open", _, socket) do
    %{target: target, label: label, current_company: com, current_user: user} = socket.assigns

    if ready?(target, com, user) do
      url = PhoneUpload.url(target, label, com, user)
      svg = url |> QRCode.create(:medium) |> QRCode.render(:svg) |> elem(1)
      {:noreply, assign(socket, qr: svg, url: url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close", _, socket), do: {:noreply, assign(socket, qr: nil)}

  defp ready?({:tray, id}, com, user), do: match?({:ok, _}, Trays.open(id, com, user))
  defp ready?({:note, _id}, _com, _user), do: true

  # The QR keeps a white ground in dark mode: phone cameras read dark-on-light
  # codes most reliably.
  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id} class="relative inline-flex">
      <button
        type="button"
        id={"#{@id}-open"}
        phx-click="open"
        phx-target={@myself}
        class="rounded border border-gray-400 px-2 text-sm hover:bg-gray-100 dark:border-gray-500 dark:hover:bg-gray-700"
      >
        📱 {gettext("From phone")}
      </button>
      <div
        :if={@qr}
        id={"#{@id}-qr"}
        class="absolute left-0 top-8 z-30 w-64 rounded-xl border border-gray-300 bg-white p-3 text-center shadow-lg dark:border-gray-600 dark:bg-gray-900"
      >
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click="close"
          phx-target={@myself}
          class="absolute right-2 top-1 text-gray-500 dark:text-gray-400"
          title={gettext("Close")}
        >
          ✕
        </button>
        <div class="mx-auto w-48 rounded bg-white p-1 [&>svg]:h-auto [&>svg]:w-full">
          {Phoenix.HTML.raw(@qr)}
        </div>
        <p class="mt-2 text-xs text-gray-600 dark:text-gray-300">
          {gettext("Scan with your phone camera. Works for 10 minutes.")}
        </p>
        <a
          href={@url}
          target="_blank"
          class="mt-1 block truncate text-xs text-sky-600 dark:text-sky-400"
        >
          {@url}
        </a>
      </div>
    </span>
    """
  end
end
