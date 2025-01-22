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
      <div class="w-[30%] border border-gray-300">
        <.link
          class="hover:font-bold"
          navigate={~p"/companies/#{@company.id}/employees/#{@obj.id}/edit"}
        >
          {@obj.employee_name}
        </.link>
      </div>
      <%= for {ps, ps_id, yr, mth} <- @obj.pay_list do %>
        <div class="flex w-[23.3333%] border border-gray-300">
          <div class="w-[40%]">
            <.link
              class="hover:font-bold text-orange-600"
              navigate={card_url(yr, mth, @obj.employee_name, @company)}
            >
              Card
            </.link>
          </div>

          <div class="w-[60%]">
            <.link
              :if={is_nil(ps)}
              navigate={new_payslip_url(@obj.id, yr, mth, @company)}
              class=" text-blue-600 hover:font-bold"
            >
              New Pay
            </.link>

            <input
              :if={!is_nil(ps)}
              class="mb-1 border-green-600 rounded checked:bg-green-600"
              id={"checkbox_#{ps_id}"}
              name={"checkbox[#{ps_id}]"}
              type="checkbox"
              class="rounded border-gray-400 checked:bg-gray-400"
              phx-click="check_click"
              phx-value-object-id={ps_id}
            />

            <.link
              :if={!is_nil(ps)}
              navigate={"/companies/#{@company.id}/PaySlip/#{ps_id}/view"}
              class="text-green-600 hover:font-bold"
            >
              {ps}
            </.link>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
