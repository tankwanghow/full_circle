defmodule FullCircleWeb.PunchDeviceLive.Index do
  use FullCircleWeb, :live_view
  alias FullCircle.PunchGate

  @impl true
  def mount(_params, _session, socket) do
    if PunchGate.list_devices(socket.assigns.current_company, socket.assigns.current_user) ==
         :not_authorise do
      {:ok,
       socket
       |> put_flash(:error, gettext("Not Authorized!"))
       |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/dashboard")}
    else
      {:ok,
       socket
       |> assign(page_title: gettext("Punch Devices"))
       |> assign(pairing: nil)
       |> assign(form: to_form(%{"name" => ""}, as: :device))
       |> load_devices()}
    end
  end

  defp load_devices(socket) do
    devices = PunchGate.list_devices(socket.assigns.current_company, socket.assigns.current_user)
    assign(socket, devices: devices)
  end

  @impl true
  def handle_event("create", %{"device" => %{"name" => name}}, socket) do
    case PunchGate.create_device(
           name,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, {device, plain}} ->
        base = FullCircleWeb.Endpoint.url()
        payload = "fcpair:#{device.id}:#{plain}:#{base}"
        svg = QRCode.create(payload, :high) |> QRCode.render(:svg) |> elem(1)

        {:noreply,
         socket
         |> assign(pairing: %{payload: payload, svg: svg, name: device.name})
         |> load_devices()
         |> put_flash(:success, gettext("Device created. Scan the QR with the gate phone now."))}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(cs, as: :device))}

      :not_authorise ->
        {:noreply, put_flash(socket, :error, gettext("Not Authorized!"))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    device = Enum.find(socket.assigns.devices, &(&1.id == id))

    case PunchGate.revoke_device(
           device,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> load_devices() |> put_flash(:success, gettext("Revoked"))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not Authorized!"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="device-form" phx-submit="create" class="flex gap-2 justify-center mb-4">
        <.input field={@form[:name]} label={gettext("Gate name")} />
        <.button class="mt-5">{gettext("Pair new phone")}</.button>
      </.form>
      <div :if={@pairing} class="text-center mb-4 border p-4">
        <p class="font-bold">{@pairing.name}</p>
        <div class="inline-block">{raw(@pairing.svg)}</div>
        <p class="text-xs break-all">{@pairing.payload}</p>
        <p class="text-rose-600">
          {gettext("This code is shown once. Scan it on the gate phone now.")}
        </p>
      </div>
      <div :for={d <- @devices} class="flex justify-between border-b py-2">
        <div>
          {d.name}
          <span :if={d.revoked_at} class="text-rose-600">({gettext("revoked")})</span>
        </div>
        <button :if={is_nil(d.revoked_at)} phx-click="revoke" phx-value-id={d.id} class="red button">
          {gettext("Revoke")}
        </button>
      </div>
    </div>
    """
  end
end
