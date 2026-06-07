defmodule FullCircleWeb.PayRunLive.IndexComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.PayRun

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

  defp money(nil), do: ""
  defp money(d), do: Number.Delimit.number_to_delimited(d)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={"#{@ex_class} flex bg-gray-200 hover:bg-gray-300 text-center"}>
      <div class="w-[24%] border border-gray-300 py-1">
        <.link
          class="hover:font-bold"
          navigate={~p"/companies/#{@company.id}/employees/#{@obj.id}/edit"}
        >
          {@obj.employee_name}
        </.link>
      </div>

      <.month_block
        :for={{pay, idx} <- Enum.with_index(@obj.pay_list)}
        pay={pay}
        obj={@obj}
        company={@company}
        col_class={col_class(idx)}
        current?={idx == 0}
      />
    </div>
    """
  end

  # Current (newest) month is wide — it carries unprocessed notes/advances; older months are tight.
  defp col_class(0), do: "w-[32%]"
  defp col_class(_), do: "w-[22%]"

  defp month_block(assigns) do
    assigns = assign(assigns, :state, PayRun.cell_state(assigns.obj.status, assigns.pay))

    ~H"""
    <div class={[
      @col_class,
      "border border-gray-300 flex items-center justify-between px-3 py-1 gap-1 text-sm"
    ]}>
      <%= case @state do %>
        <% :done -> %>
          <div>
            <input
              id={"checkbox_#{@pay.slip_id}"}
              name={"checkbox[#{@pay.slip_id}]"}
              type="checkbox"
              class="rounded border-green-600 checked:bg-green-600"
              phx-click="check_click"
              phx-value-object-id={@pay.slip_id}
            />
            <.link
              navigate={"/companies/#{@company.id}/PaySlip/#{@pay.slip_id}/view"}
              class="text-left text-green-700 hover:font-bold"
            >
              {@pay.slip_no}
            </.link>
          </div>
          <span>{money(@pay.net_pay)}</span>
        <% :pending -> %>
          <.link
            navigate={card_url(@pay.year, @pay.month, @obj.employee_name, @company)}
            class="text-blue-600 hover:font-bold"
          >
            {gettext("New Pay")}
          </.link>
          <span :if={@current?} class="grow flex gap-1 justify-center flex-wrap">
            <span
              :if={@pay.unproc_note_count > 0}
              class="bg-amber-200 rounded px-1"
              title={gettext("Unprocessed salary notes")}
            >
              SN-{@pay.unproc_note_count}({money(@pay.unproc_note_sum)})
            </span>
            <span
              :if={@pay.unproc_adv_count > 0}
              class="bg-blue-200 rounded px-1"
              title={gettext("Unprocessed advances")}
            >
              ADV-{@pay.unproc_adv_count}({money(@pay.unproc_adv_sum)})
            </span>
          </span>
        <% :na -> %>
          <span class="w-full text-rose-400 italic">— {gettext("Resigned")} —</span>
      <% end %>
    </div>
    """
  end
end
