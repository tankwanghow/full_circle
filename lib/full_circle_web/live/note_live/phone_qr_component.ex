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

  # The phone pressed ✓ Close (FullCircleWeb.NoteFiles).
  @impl true
  def update(%{phone_closed: true}, socket), do: {:ok, assign(socket, qr: nil)}

  def update(assigns, socket),
    do: {:ok, socket |> assign(assigns) |> assign_new(:qr, fn -> nil end)}

  @impl true
  def handle_event("open", _, socket) do
    %{target: target, label: label, current_company: com, current_user: user} = socket.assigns

    if ready?(target, com, user) do
      url = PhoneUpload.url(target, label, com, user)
      svg = url |> QRCode.create(:medium) |> QRCode.render(:svg) |> elem(1)
      FullCircleWeb.NoteFiles.listen_phone(target, __MODULE__, socket.assigns.id)
      {:noreply, assign(socket, qr: scalable(svg), url: url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close", _, socket), do: {:noreply, assign(socket, qr: nil)}

  # QRCode renders a fixed `width`/`height` and no viewBox, so CSS sizing
  # crops it instead of scaling it. Swap the size for a viewBox.
  defp scalable(svg) do
    String.replace(svg, ~r/<svg width="(\d+)" height="(\d+)"/, ~S(<svg viewBox="0 0 \1 \2"),
      global: false
    )
  end

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
        title={gettext("Add from phone")}
        class="whitespace-nowrap rounded-full border border-gray-300 px-3 py-0.5 text-sm hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
      >
        📱<span class="ml-1 hidden @[28rem]:inline">{gettext("Phone")}</span>
      </button>
      <%!-- A centered modal, fixed to the viewport: the notes panel clips
           its overflow, so a popover under the button was cut off. --%>
      <div
        :if={@qr}
        id={"#{@id}-qr"}
        data-no-post-open
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      >
        <div
          class="relative w-72 rounded-xl border border-gray-300 bg-white p-4 text-center shadow-xl dark:border-gray-600 dark:bg-gray-900"
          phx-click-away="close"
          phx-target={@myself}
        >
          <button
            type="button"
            id={"#{@id}-close"}
            phx-click="close"
            phx-target={@myself}
            class="absolute right-2 top-1 text-lg text-gray-500 dark:text-gray-400"
            title={gettext("Close")}
          >
            ✕
          </button>
          <p class="mb-2 font-semibold">📱 {gettext("Add from phone")}</p>
          <div class="mx-auto w-56 rounded bg-white p-2 [&>svg]:h-auto [&>svg]:w-full">
            {Phoenix.HTML.raw(@qr)}
          </div>
          <p class="mt-2 text-sm text-gray-600 dark:text-gray-300">
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
      </div>
    </span>
    """
  end
end
