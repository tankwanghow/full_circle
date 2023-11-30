defmodule FullCircleWeb.CsvHtml do
  use Phoenix.Component

  def headers(headers, row_class, cols_width, col_class, assigns) do
    assigns =
      assign(assigns, :headers, headers)
      |> assign(:row_class, row_class)
      |> assign(:cols_width, cols_width)
      |> assign(:col_class, col_class)

    ~H"""
    <div class={@row_class}>
      <%= for h <- @headers do %>
        <div class={"w-[#{Enum.at(@cols_width, Enum.find_index(@headers, fn x -> x == h end))}] #{@col_class}"}>
          <%= h %>
        </div>
      <% end %>
    </div>
    """
  end

  def data(fields, data, row_class, cols_width, col_class, assigns) do
    assigns =
      assign(assigns, :data, data)
      |> assign(:fields, fields)
      |> assign(:row_class, row_class)
      |> assign(:cols_width, cols_width)
      |> assign(:col_class, col_class)

    ~H"""
    <%= for d <- @data do %>
      <div class={@row_class}>
        <%= for f <- @fields do %>
          <div class={"w-[#{Enum.at(@cols_width, Enum.find_index(@fields, fn x -> x == f end))}] #{@col_class}"}>
            <%= d[f] %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end
end
