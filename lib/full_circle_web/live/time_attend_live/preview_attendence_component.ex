defmodule FullCircleWeb.PreviewAttendenceLive.Component do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Preview Attendences"))}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)
    {:ok, socket}
  end

  @impl true
  def handle_event("show_preview", %{"id" => id}, socket) do
    punch_card_id = id |> String.trim_leading("id_") |> Base.decode16!()
    attendences = parse_raw_attentence_to_attrs(socket.assigns.raw_attendences, punch_card_id)

    {:noreply,
     socket
     |> assign(show_preview: true)
     |> assign(:punch_card_id, punch_card_id)
     |> assign(attendences: attendences)}
  end

  @impl true
  def handle_event("hide_preview", _, socket) do
    {:noreply, socket |> assign(show_preview: false)}
  end

  defp parse_raw_attentence_to_attrs(rows, id) do
    date_range = Enum.at(rows, 2) |> Enum.at(2) |> extract_date_range()

    rows
    |> Enum.drop(4)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [info, att] ->
      info_a = Enum.reject(info, fn i -> i == "" end)

      punch_card_id =
        "#{Enum.at(info_a, 3)}.#{Enum.at(info_a, 1)}.#{Enum.at(info_a, 5)}"
        |> String.replace(" ", "")

      if punch_card_id == id do
        Enum.map(att, fn x ->
          Regex.scan(~r/\d{2}:\d{2}/, x)
          |> List.flatten()
          |> Enum.map(fn time_str ->
            [hour, minute] = String.split(time_str, ":") |> Enum.map(&String.to_integer/1)
            Time.new!(hour, minute, 0)
          end)
        end)
        |> Enum.zip(date_range)
        |> Enum.map(fn {times, dt} ->
          %{
            punch_card_id: punch_card_id,
            date: dt,
            stamps: times
          }
        end)
      end
    end)
    |> List.flatten()
    |> Enum.reject(fn x -> is_nil(x) end)
  end

  defp extract_date_range(date_line) do
    [start_date, end_date] =
      Regex.scan(~r/\d{4}-\d{2}-\d{2}/, date_line)
      |> List.flatten()
      |> Enum.map(&Date.from_iso8601!/1)

    Date.range(start_date, end_date) |> Enum.to_list()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.link
        phx-target={@myself}
        phx-click={:show_preview}
        phx-value-id={@id}
        class="blue button block"
      >
        {@label}
      </.link>
      <.modal
        :if={@show_preview}
        id={"object-modal-#{@id}"}
        show
        on_cancel={JS.push("hide_preview", target: "##{@id}")}
        max_w="max-w-4xl"
      >
        <div class="max-w-full text-black">
          <p class="w-full text-3xl text-center font-medium mb-1">
            {@page_title}
          </p>
          <p class="w-full text-center font-medium mb-1">
            {@punch_card_id}
          </p>
          <div class="font-medium flex flex-row text-center mt-2 tracking-tighter">
            <div class="w-[20%] border rounded bg-orange-200 border-orange-600 px-2 py-1">
              {gettext("Date")}
            </div>
            <div class="w-[80%] border rounded bg-orange-200 border-orange-600 px-2 py-1">
              {gettext("Credit")}
            </div>
          </div>
          <%= for obj <- @attendences do %>
            <div class="flex flex-row text-center tracking-tighter">
              <div class="w-[20%] border rounded bg-gray-100 border-gray-400">
                {obj.date}
              </div>
              <div class="w-[80%] border rounded bg-gray-100 border-gray-400">
                {obj.stamps
                |> Enum.map(fn x -> Time.to_string(x) |> String.slice(0..4) end)
                |> Enum.join(", ")}
              </div>
            </div>
          <% end %>
        </div>
      </.modal>
    </div>
    """
  end
end
