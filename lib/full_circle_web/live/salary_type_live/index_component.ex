defmodule FullCircleWeb.SalaryTypeLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={"#{@ex_class} text-center bg-gray-200 border-gray-500 hover:bg-gray-300 border-b py-1"}
    >
      <%= if !FullCircle.HR.is_default_salary_type?(@obj) do %>
        <.link
          class="hover:font-bold text-blue-600"
          navigate={~p"/companies/#{@current_company.id}/salary_types/#{@obj.id}/edit"}
        >
          {@obj.name}
        </.link>
      <% else %>
        <%= if @current_role == "admin" do %>
          <.link
            class="hover:font-bold text-purple-600"
            navigate={~p"/companies/#{@current_company.id}/salary_types/#{@obj.id}/edit"}
          >
            {@obj.name}
          </.link>
        <% else %>
          <span class="font-bold text-rose-600">
            {@obj.name}
          </span>
        <% end %>
      <% end %>
      <span class={"type-badge px-2 py-0.5 mx-1 rounded-full text-xs font-semibold #{type_badge_class(@obj.type)}"}>
        {@obj.type}
      </span>
      &#8226; {@obj.db_ac_name} &#8226; {@obj.cr_ac_name} &#8226; {@obj.cal_func}
      <span :if={@obj.statutory_code} class="font-mono text-xs text-gray-600">
        &#8226; {@obj.statutory_code}
      </span>
    </div>
    """
  end

  # Rows keep a fixed light bg-gray-200 background in both themes, so the
  # badge palette needs no dark: variants. Matches the bundle-import diff pills.
  defp type_badge_class("Addition"), do: "bg-green-200 text-green-800"
  defp type_badge_class("FixedWages"), do: "bg-teal-200 text-teal-800"
  defp type_badge_class("Deduction"), do: "bg-rose-200 text-rose-800"
  defp type_badge_class("Contribution"), do: "bg-amber-200 text-amber-800"
  defp type_badge_class("Bonus"), do: "bg-sky-200 text-sky-800"
  defp type_badge_class("LeaveTaken"), do: "bg-violet-200 text-violet-800"
  defp type_badge_class(_), do: "bg-gray-300 text-gray-800"
end
