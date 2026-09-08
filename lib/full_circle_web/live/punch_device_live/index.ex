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
       |> assign_pairing_origin()
       |> load_devices()}
    end
  end

  # The QR on screen belongs to a device that no longer accepts uploads.
  defp clear_pairing_for(socket, device_id) do
    case socket.assigns.pairing do
      %{device_id: ^device_id} -> assign(socket, pairing: nil)
      _ -> socket
    end
  end

  defp load_devices(socket) do
    devices = PunchGate.list_devices(socket.assigns.current_company, socket.assigns.current_user)
    assign(socket, devices: devices)
  end

  defp assign_pairing_origin(socket) do
    base =
      case Phoenix.LiveView.get_connect_info(socket, :uri) do
        %URI{scheme: scheme, host: host, port: port}
        when is_binary(scheme) and is_binary(host) ->
          origin(scheme, host, port)

        _ ->
          FullCircleWeb.Endpoint.url() |> String.trim_trailing("/")
      end

    socket
    |> assign(:pairing_base, base)
    |> assign(:pairing_unreachable?, pairing_unreachable?(base))
  end

  defp origin(scheme, host, port) do
    if port in [nil, URI.default_port(scheme)] do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp pairing_unreachable?(base) do
    case URI.parse(base) do
      %URI{host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  @impl true
  def handle_event("create", %{"device" => %{"name" => name}}, socket) do
    case PunchGate.create_device(
           name,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, {device, plain}} ->
        base = socket.assigns.pairing_base
        payload = "fcpair:#{device.id}:#{plain}:#{base}"
        svg = QRCode.create(payload, :high) |> QRCode.render(:svg) |> elem(1)

        {:noreply,
         socket
         |> assign(pairing: %{
           payload: payload,
           svg: svg,
           name: device.name,
           device_id: device.id
         })
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
        {:noreply,
         socket
         |> clear_pairing_for(id)
         |> load_devices()
         |> put_flash(:success, gettext("Revoked"))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not Authorized!"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <p :if={@pairing_unreachable?} class="text-center text-rose-600 mb-4">
        {gettext(
          "This page is localhost. The gate phone cannot reach localhost — open Punch Devices as http://<this-computer-LAN-IP>:4000 (the same address phone Chrome used), then pair."
        )}
      </p>
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
      <div id="devices-list">
        <div :for={d <- @devices} id={"device-#{d.id}"} class="flex justify-between border-b py-2">
          <div>{d.name}</div>
          <button phx-click="revoke" phx-value-id={d.id} class="red button">
            {gettext("Revoke")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
