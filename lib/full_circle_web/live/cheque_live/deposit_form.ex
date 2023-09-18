defmodule FullCircleWeb.ChequeLive.DepositForm do
  use FullCircleWeb, :live_view

  alias FullCircle.{Cheque, Reporting}
  alias FullCircle.Cheque.Deposit
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["deposit_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(qry_cheques: [])}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Deposit"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Deposit,
          %Deposit{},
          %{"deposit_no" => "...new...", "deposit_date" => Timex.today()},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      Cheque.get_deposit!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs = Deposit.changeset(object, %{})

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Deposit") <> " " <> object.deposit_no)
    |> assign(:form, to_form(cs))
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["deposit", "bank_name"],
          "deposit" => params
        },
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "bank_name",
        "bank_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["deposit", "funds_from_name"],
          "deposit" => params
        },
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "funds_from_name",
        "funds_from_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"deposit" => params},
        socket
      ) do
    validate(params, socket)
  end

  @impl true
  def handle_event("add_chq", %{"chq-id" => id}, socket) do
    wl = [:id, :bank, :cheque_no, :city, :state, :due_date, :amount]

    chq =
      socket.assigns.qry_cheques
      |> Enum.find(fn x -> x.id == id end)
      |> Map.reject(fn {k, _} -> !Enum.any?(wl, fn x -> x == k end) end)

    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:cheques, chq)
      |> Map.put(:action, socket.assigns.live_action)
      |> Deposit.compute_fields()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_chq", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :cheques)
      |> Map.put(:action, socket.assigns.live_action)
      |> Deposit.compute_fields()

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("save", %{"deposit" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("find_chqs", %{"d_date" => d_date}, socket) do
    {:noreply, socket |> find_qry_cheques(d_date)}
  end

  defp save(socket, :new, params) do
    case FullCircle.Cheque.create_deposit(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_deposit: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Deposit/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Create Deposit successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case FullCircle.Cheque.update_deposit(
           socket.assigns.form.source.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_deposit: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Deposit/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Update Deposit successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp find_qry_cheques(socket, d_date) do
    qry_cheques =
      Reporting.post_dated_cheques(
        "",
        "In-Hand",
        "",
        d_date,
        socket.assigns.current_company
      )

    socket |> assign(qry_cheques: qry_cheques)
  end

  defp found_in_chqs?(source, id) do
    Enum.any?(Ecto.Changeset.fetch_field!(source, :cheques), fn x ->
      x.id == id
    end)
  end

  defp validate(params, socket) do
    dep_cs =
      Deposit.changeset(socket.assigns.form.data, params)
      |> Map.merge(%{action: socket.assigns.live_action})

    socket = assign(socket, form: to_form(dep_cs))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <%= Phoenix.HTML.Form.hidden_input(@form, :deposit_no) %>
        <div class="flex flex-row flex-nowarp gap-1">
          <div class="w-2/12">
            <.input field={@form[:deposit_date]} label={gettext("Deposit Date")} type="date" />
          </div>
          <div class="w-4/12">
            <.input
              field={@form[:bank_name]}
              label={gettext("Deposit To")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
          <div class="w-4/12">
            <.input
              field={@form[:funds_from_name]}
              label={gettext("Funds From")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
          <div class="w-2/12 grow shrink">
            <.input
              field={@form[:funds_amount]}
              label={gettext("Funds Amount")}
              phx-debounce="500"
              type="number"
              step="0.01"
              feedback={true}
            />
          </div>

          <%= Phoenix.HTML.Form.hidden_input(@form, :bank_id) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :funds_from_id) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :company_id) %>
        </div>

        <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
          <div class="detail-header w-[16%]"><%= gettext("Bank") %></div>
          <div class="detail-header w-[16%]"><%= gettext("Cheque No") %></div>
          <div class="detail-header w-[16%]"><%= gettext("City") %></div>
          <div class="detail-header w-[17%]"><%= gettext("State") %></div>
          <div class="detail-header w-[16%]"><%= gettext("Due Date") %></div>
          <div class="detail-header w-[16%]"><%= gettext("Amount") %></div>
          <div class="w-[3%]"><%= gettext("") %></div>
        </div>

        <.inputs_for :let={dtl} field={@form[:cheques]}>
          <div class={"flex flex-row flex-wrap #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :id) %>
            <div feedback={true} class="w-[16%]"><.input field={dtl[:bank]} readonly /></div>
            <div class="w-[16%]"><.input field={dtl[:cheque_no]} readonly /></div>
            <div class="w-[16%]"><.input field={dtl[:city]} readonly /></div>
            <div class="w-[17%]"><.input field={dtl[:state]} readonly /></div>
            <div class="w-[16%]"><.input type="date" field={dtl[:due_date]} readonly /></div>
            <div class="w-[16%]">
              <.input type="number" step="0.01" field={dtl[:amount]} readonly />
            </div>
            <div class="w-[3%] mt-1 text-rose-500">
              <.link phx-click={:delete_chq} phx-value-index={dtl.index} tabindex="-1">
                <.icon name="hero-trash-solid" class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
            </div>
          </div>
        </.inputs_for>
        <div class="flex flex-row flex-wrap">
            <div class="w-[81%]" />
            <div class="w-[16%]">
              <.input feedback={true} type="number" step="0.01" field={@form[:cheques_amount]} readonly />
            </div>
            <div class="w-[3%] mt-1 text-rose-500" />
          </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            new_url={~p"/companies/#{@current_company.id}/Deposit/new"}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="deposits"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="Deposit"
            doc_no={@form.data.deposit_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>

    <div class="text-center w-8/12 mx-auto border rounded-lg border-blue-500 bg-blue-100 p-4">
      <div class="mb-2">
        <.link
          phx-click={:find_chqs}
          phx-value-d_date={Ecto.Changeset.fetch_field!(@form.source, :deposit_date)}
          class="text-lg hover:font-bold text-blue-600"
        >
          <%= gettext("Show Cheques Due Date until") %>
          <%= Ecto.Changeset.fetch_field!(@form.source, :deposit_date)
          |> FullCircleWeb.Helpers.format_date() %>
        </.link>
      </div>

      <div class="text-center font-medium flex flex-row tracking-tighter bg-amber-200 border-amber-400 border-y-2">
        <div class="w-[12%] px-2 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[36%] px-2 py-1">
          <%= gettext("Customer") %>
        </div>
        <div class="w-[10%] px-2 py-1">
          <%= gettext("Bank") %>
        </div>
        <div class="w-[10%] px-2 py-1 ">
          <%= gettext("Chq No") %>
        </div>
        <div class="w-[12%] px-2 py-1 ">
          <%= gettext("Due Date") %>
        </div>
        <div class="w-[18%] px-2 py-1">
          <%= gettext("Amount") %>
        </div>
        <div class="w-[3%]" />
      </div>

      <div class="bg-gray-50">
        <%= for obj <- @qry_cheques do %>
          <div class="flex flex-row border-b bg-gray-200 border-gray-400 text-center">
            <div class="border w-[12%] px-1 py-1">
              <span><%= obj.receipt_date %></span>
            </div>
            <div class="border w-[36%] px-1 py-1">
              <span><%= obj.contact_name %></span>
            </div>
            <div class="border w-[10%] px-1 py-1">
              <%= obj.bank %>
            </div>
            <div class="border w-[10%] px-1 py-1">
              <%= obj.cheque_no %>
            </div>
            <div class="border w-[12%] px-1 py-1">
              <%= obj.due_date %>
            </div>
            <div class="border w-[18%] px-1 py-1">
              <%= obj.amount |> Number.Delimit.number_to_delimited() %>
            </div>
            <div
              :if={!found_in_chqs?(@form.source, obj.id)}
              class="border w-[3%] text-green-500 cursor-pointer"
            >
              <.link phx-click={:add_chq} phx-value-chq-id={obj.id} tabindex="-1">
                <.icon name="hero-plus-circle-solid" class="h-7 w-7" />
              </.link>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
