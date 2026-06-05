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

  defp new_payslip_url(id, yr, mth, com) do
    qry = %{"emp_id" => id, "month" => mth, "year" => yr}
    "/companies/#{com.id}/PaySlip/new?#{URI.encode_query(qry)}"
  end

  defp money(nil), do: ""
  defp money(d), do: Number.Delimit.number_to_delimited(d)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={"#{@ex_class} flex bg-gray-200 hover:bg-gray-300 text-center"}>
      <div class="w-[16%] border border-gray-300 py-1">
        <.link
          class="hover:font-bold"
          navigate={~p"/companies/#{@company.id}/employees/#{@obj.id}/edit"}
        >
          {@obj.employee_name}
        </.link>
        <div :if={@obj.status == "Resigned"} class="text-xs text-rose-600">
          {gettext("Resigned")}
        </div>
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
  defp col_class(0), do: "w-[40%]"
  defp col_class(_), do: "w-[22%]"

  defp month_block(assigns) do
    assigns = assign(assigns, :state, PayRun.cell_state(assigns.obj.status, assigns.pay))

    ~H"""
    <div class={[@col_class, "border border-gray-300 flex items-center px-1 py-1 gap-1 text-sm"]}>
      <%= case @state do %>
        <% :done -> %>
          <input
            id={"checkbox_#{@pay.slip_id}"}
            name={"checkbox[#{@pay.slip_id}]"}
            type="checkbox"
            class="shrink-0 rounded border-green-600 checked:bg-green-600"
            phx-click="check_click"
            phx-value-object-id={@pay.slip_id}
          />
          <.link
            navigate={"/companies/#{@company.id}/PaySlip/#{@pay.slip_id}/view"}
            class="shrink-0 w-16 text-left text-green-700 hover:font-bold"
          >
            {@pay.slip_no}
          </.link>
          <span class="grow text-right font-mono">{money(@pay.net_pay)}</span>
          <.link
            navigate={card_url(@pay.year, @pay.month, @obj.employee_name, @company)}
            class="shrink-0 text-orange-600 hover:font-bold"
          >
            {gettext("Card")}
          </.link>
        <% :pending -> %>
          <.link
            navigate={new_payslip_url(@obj.id, @pay.year, @pay.month, @company)}
            class="shrink-0 text-blue-600 hover:font-bold"
          >
            {gettext("New Pay")}
          </.link>
          <span :if={@current?} class="grow flex gap-1 justify-center flex-wrap">
            <span
              :if={@pay.unproc_note_count > 0}
              class="bg-amber-200 rounded px-1"
              title={gettext("Unprocessed salary notes")}
            >
              ✎ {@pay.unproc_note_count}/{money(@pay.unproc_note_sum)}
            </span>
            <span
              :if={@pay.unproc_adv_count > 0}
              class="bg-blue-200 rounded px-1"
              title={gettext("Unprocessed advances")}
            >
              $ {@pay.unproc_adv_count}/{money(@pay.unproc_adv_sum)}
            </span>
          </span>
          <span :if={not @current?} class="grow"></span>
          <.link
            navigate={card_url(@pay.year, @pay.month, @obj.employee_name, @company)}
            class="shrink-0 text-orange-600 hover:font-bold"
          >
            {gettext("Card")}
          </.link>
        <% :na -> %>
          <span class="w-full text-gray-400 italic">— {gettext("Resigned")}</span>
      <% end %>
    </div>
    """
  end
end
