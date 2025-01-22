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
          {h}
        </div>
      <% end %>
    </div>
    """
  end

  def data(fields, data, display_func, row_class, cols_width, col_class, assigns) do
    assigns =
      assign(assigns, :data, data)
      |> assign(dis_func: display_func || [])
      |> assign(:fields, fields)
      |> assign(:row_class, row_class)
      |> assign(:cols_width, cols_width)
      |> assign(:col_class, col_class)

    ~H"""
    <%= for d <- @data do %>
      <div class={@row_class}>
        <%= for f <- @fields do %>
          <% i = Enum.find_index(@fields, fn x -> x == f end) %>
          <div class={"w-[#{Enum.at(@cols_width, i)}] #{@col_class}"}>
            <% func = Enum.at(@dis_func, i) %>
            <%= if !is_nil(func) do %>
              {func.(d[f])}
            <% else %>
              {d[f]}
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end
end
