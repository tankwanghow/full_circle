defmodule FullCircleWeb.ReconLive do
  use FullCircleWeb, :live_view

  # alias FullCircle.HR

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(pic: nil)}
  end

  @impl true
  def handle_event("got-a-face", params, socket) do

    {:noreply, socket |> assign(pic: params) }

    # String.replace(params, "data:image/png;base64,", "")) }
  end

  @impl true
  def handle_event("save-face", %{"facedescriptor" => params}, socket) do
    IO.inspect(String.split(params, ",") |> Enum.map(fn x -> String.to_float(x) end))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="face-recon"
      phx-hook="FaceRecon"
      style="margin-left: 50px; margin-top: 50px; width: 50%; height: 50%;"
    >
      <video id="video" playsinline class="video"></video>
      <canvas
        id="canvas"
        class="canvas"
        style="position: absolute; top: 0; left: 0; margin: inherit; z-index: 10"
      >
      </canvas>
      <div id="log" style="overflow-y: scroll; height: 16.5rem"></div>
      <.link id="save-face">Save Face</.link>
      <div class="output">
        <img id="photo" alt="The screen capture will appear in this box." src={@pic} />
      </div>
    </div>
    """
  end
end
