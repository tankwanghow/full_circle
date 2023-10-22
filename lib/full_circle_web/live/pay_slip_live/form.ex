defmodule FullCircleWeb.PaySlipLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.PaySlipOp
  alias FullCircleWeb.PaySlipLive.{SalaryNoteComponent, AdvanceComponent}
  alias FullCircle.StdInterface
  alias FullCircle.HR.PaySlip

  @impl true
  def mount(params, _session, socket) do
    month = params["month"]
    year = params["year"]
    emp_id = params["emp_id"]
    id = params["id"]

    socket =
      case socket.assigns.live_action do
        :new ->
          mount_new(socket, emp_id, month |> String.to_integer(), year |> String.to_integer())

        :edit ->
          mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket, emp_id, month, year) do
    emp =
      FullCircle.HR.get_employee!(
        emp_id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Pay Slip"))
    |> assign(employee: emp)
    |> assign(
      form:
        to_form(
          PaySlipOp.generate_new_changeset_for(
            emp,
            month,
            year,
            socket.assigns.current_company
          )
        )
    )
  end

  defp mount_edit(socket, _id) do
    socket
    # obj =
    #   HR.get_salary_note!(id, socket.assigns.current_company, socket.assigns.current_user)

    # socket
    # |> assign(live_action: :edit)
    # |> assign(id: id)
    # |> assign(page_title: gettext("Edit Pay Slip") <> " " <> obj.slip_no)
    # |> assign(
    #   :form,
    # )
  end

  @impl true
  def handle_event("calculate", _, socket) do
    {:noreply, socket |> assign(form: to_form(PaySlipOp.calculate_pay(socket.assigns.employee, socket.assigns.form.source)))}
  end

  def handle_event("validate", %{"pay_slip" => params}, socket) do
    validate(params, socket)
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        PaySlip,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )

    # |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <%= Phoenix.HTML.Form.hidden_input(@form, :slip_no) %>
        <div class="flex flex-nowrap gap-1 mb-2">
          <div class="w-[30%]">
            <%= Phoenix.HTML.Form.hidden_input(@form, :employee_id) %>
            <.input
              field={@form[:employee_name]}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="w-[15%]">
            <.input feedback field={@form[:slip_date]} label={gettext("Date")} type="date" />
          </div>
          <div class="w-[7%]">
            <.input field={@form[:pay_month]} label={gettext("Month")} type="number" />
          </div>
          <div class="w-[7%]">
            <.input field={@form[:pay_year]} label={gettext("Year")} type="number" />
          </div>
          <div class="w-[30%]">
            <%= Phoenix.HTML.Form.hidden_input(@form, :funds_account_id) %>
            <.input
              field={@form[:funds_account_name]}
              label={gettext("Funds From")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
          <a onclick="history.back();" class="w-[7%] h-10 mt-5 blue button"><%= gettext("Back") %></a>
          <.link phx-click={:calculate}>count</.link>
        </div>
        <div class="flex flex-row text-center font-semibold">
          <div class="w-[14%]"><%= gettext("Doc Date") %></div>
          <div class="w-[11%]"><%= gettext("Doc No") %></div>
          <div class="w-[21%]"><%= gettext("Salary Type") %></div>
          <div class="w-[24%]"><%= gettext("Description") %></div>
          <div class="w-[8%]"><%= gettext("Quantity") %></div>
          <div class="w-[9%]"><%= gettext("Price") %></div>
          <div class="w-[11%]"><%= gettext("Amount") %></div>
          <div class="w-[2%]"></div>
        </div>

        <.live_component
          module={SalaryNoteComponent}
          id="additions"
          klass="Addition"
          types={@form[:additions]}
          total={@form[:addition_amount].value}
          total_label={gettext("Addition Amount")}
          current_company={@current_company}
          current_user={@current_user}
        />

        <.live_component
          module={AdvanceComponent}
          id="advances"
          types={@form[:advances]}
          total={@form[:advance_amount].value}
          total_label={gettext("Advance Amount")}
          current_company={@current_company}
          current_user={@current_user}
        />

        <.live_component
          module={SalaryNoteComponent}
          id="deductions"
          klass="Deduction"
          types={@form[:deductions]}
          total={@form[:deduction_amount].value}
          total_label={gettext("Deduction Amount")}
          current_company={@current_company}
          current_user={@current_user}
        />

        <.live_component
          module={SalaryNoteComponent}
          id="contributions"
          klass="Contribution"
          types={@form[:contributions]}
          total={@form[:contribution_amount].value}
          total_label={gettext("Contribution Amount")}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex flex-row text-center font-semibold">
          <div class="w-[14%] mt-1 text-orange-500 text-left">
            <.link phx-click={:add_note} class="hover:font-bold focus:font-bold">
              <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Note") %>
            </.link>
          </div>
          <div class="w-[73%] text-right px-1 pt-1">
            <%= gettext("Pay Slip Total") %>
          </div>
          <div class="w-[11%]"><.input readonly field={@form[:pay_slip_amount]} type="number" /></div>
          <div class="w-[2%]"></div>
        </div>
      </.form>
    </div>
    """
  end
end
