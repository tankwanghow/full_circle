defmodule FullCircleWeb.PayRunLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  defp card_url(yr, mth, name, com) do
    qry = %{
      "search[employee_name]" => name,
      "search[month]" => mth,
      "search[year]" => yr
    }

    "/companies/#{com.id}/PunchCard?#{URI.encode_query(qry)}"
  end

  defp new_payslip_url(id, yr, mth, com) do
    qry = %{
      "emp_id" => id,
      "month" => mth,
      "year" => yr
    }

    "/companies/#{com.id}/PaySlip/new?#{URI.encode_query(qry)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={"#{@ex_class} flex bg-gray-200 hover:bg-gray-300 text-center"}>
      <.link
        class="w-[30%] hover:font-bold border-l border-r border-b border-gray-600"
        navigate={~p"/companies/#{@company.id}/employees/#{@obj.id}/edit"}
      >
        <%= @obj.employee_name %>
      </.link>
      <%= for {ps, ps_id, yr, mth} <- @obj.pay_list do %>
        <.link
          class="w-[8.3%] hover:font-bold text-orange-600 border-b border-gray-600"
          navigate={card_url(yr, mth, @obj.employee_name, @company)}
        >
          Card
        </.link>
        <.link
          :if={is_nil(ps)}
          navigate={new_payslip_url(@obj.id, yr, mth, @company)}
          class="w-[15%] text-blue-600 border-b border-r border-gray-600 hover:font-bold"
        >
          New Pay
        </.link>
        <.link
          :if={!is_nil(ps)}
          navigate={"/companies/#{@company.id}/PaySlip/#{ps_id}/view"}
          class="w-[15%] text-green-600 border-b border-r border-gray-600 hover:font-bold"
        >
          View Pay <%= ps %>
        </.link>
      <% end %>
    </div>
    """
  end
end
