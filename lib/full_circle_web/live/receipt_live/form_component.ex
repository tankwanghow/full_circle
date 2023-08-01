defmodule FullCircleWeb.ReceiptLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.ReceiveFund
  alias FullCircle.ReceiveFund.{Receipt, ReceivedCheque}
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    # Ecto.Changeset.fetch_field!(socket.assigns.form.source, :receipt_date) ||
    to = Timex.today()
    from = Timex.shift(to, months: -1)

    {:ok,
     socket
     |> assign(
       account_names: [],
       contact_names: [],
       query: %{from: from, to: to}
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)

    {:ok,
     socket
     |> assign(
       account_names: [],
       contact_names: []
     )}
  end

  @impl true
  def handle_event("add_cheque", _, socket) do
    socket = socket |> FullCircleWeb.Helpers.add_line(:received_cheques, %ReceivedCheque{})
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_tran", %{"index" => index}, socket) do
    socket =
      socket
      |> FullCircleWeb.Helpers.delete_line(String.to_integer(index), :receipt_transaction_matchers)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "contact_name"], "receipt" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "contact_name",
        :contact_names,
        "contact_id",
        &FullCircle.Accounting.contact_names/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "funds_account_name"], "receipt" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "funds_account_name",
        :account_names,
        "funds_account_id",
        &FullCircle.Accounting.funds_account_names/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["query", _], "query" => %{"from" => from, "to" => to}},
        socket
      ) do
    {:noreply, socket |> assign(query: %{from: from, to: to})}
  end

  @impl true
  def handle_event("validate", %{"receipt" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("get_trans", _, socket) do
    ctid = Ecto.Changeset.fetch_field!(socket.assigns.form.source, :contact_id)

    trans =
      ReceiveFund.receipt_match_transactions(
        ctid,
        socket.assigns.query.from,
        socket.assigns.query.to,
        socket.assigns.current_company
      )

      socket = socket |> FullCircleWeb.Helpers.add_lines(:receipt_transaction_matchers, trans)

      {:noreply, socket}
  end


  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        Receipt,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"receipt" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Receipt,
           "receipt",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, obj} ->
        send(self(), {:deleted, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :new, params) do
    case ReceiveFund.create_receipt(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_receipt: obj}} ->
        send(self(), {:created, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :edit, params) do
    case ReceiveFund.update_receipt(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_receipt: obj}} ->
        send(self(), {:updated, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        socket =
          socket
          |> assign(form: to_form(changeset))
          |> put_flash(
            :error,
            "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
          )

        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}

      {:sql_error, msg} ->
        send(self(), {:sql_error, msg})
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        phx-target={@myself}
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
      >
        <%= Phoenix.HTML.Form.hidden_input(@form, :receipt_no) %>
        <div class="flex flex-row flex-nowarp">
          <div class="w-5/12 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :contact_id) %>
            <.input
              field={@form[:contact_name]}
              label={gettext("Receive From")}
              list="contact_names"
              phx-debounce={500}
            />
          </div>
          <div class="w-5/12 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :funds_account_id) %>
            <.input
              field={@form[:funds_account_name]}
              label={gettext("Funds Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>
          <div class="w-2/12 grow shrink">
            <.input
              field={@form[:receipt_amount]}
              label={gettext("Receipt Amount")}
              type="number"
              step="0.01"
            />
          </div>
          <div class="grow shrink w-2/12">
            <.input field={@form[:receipt_date]} label={gettext("Receipt Date")} type="date" />
          </div>
        </div>
        <div class="flex flex-row flex-nowrap">
          <div class="grow shrink">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
        </div>
        <%= datalist_with_ids(@account_names, "account_names") %>
        <%= datalist_with_ids(@contact_names, "contact_names") %>

        <div class="text-center border bg-yellow-100 mt-2 p-3 rounded-lg border-yellow-400">
          Get invoices from
          <input
            type="date"
            id="query_from"
            name="query[from]"
            value={@query.from}
            class="py-1 rounded-md border border-gray-300 bg-white shadow-sm focus:border-zinc-400 focus:ring-0"
          /> to
          <input
            type="date"
            id="query_to"
            name="query[to]"
            value={@query.to}
            class="py-1 rounded-md border border-gray-300 bg-white shadow-sm focus:border-zinc-400 focus:ring-0"
          />
          <.link phx-click="get_trans" class="blue_button" phx-target={@myself}>
            Get
          </.link>

          <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
            <div class="detail-header w-[11.1rem]"><%= gettext("Doc Date") %></div>
            <div class="detail-header w-[11.1rem]"><%= gettext("Doc Type") %></div>
            <div class="detail-header w-[11.1rem]"><%= gettext("Doc No") %></div>
            <div class="detail-header w-[11.1rem]"><%= gettext("Amount") %></div>
            <div class="detail-header w-[11.1rem]"><%= gettext("Banalce") %></div>
            <div class="detail-header w-[11.1rem]"><%= gettext("Match") %></div>
          </div>
          <.inputs_for :let={dtl} field={@form[:receipt_transaction_matchers]}>
            <div class={"flex flex-row flex-wrap"}>
              <div class="w-[11.1rem]"><.input field={dtl[:doc_date]} /></div>
              <div class="w-[11.1rem]"><.input field={dtl[:doc_type]} /></div>
              <div class="w-[11.1rem]"><.input field={dtl[:doc_no]} /></div>
              <div class="w-[11.1rem]"><.input type="number" field={dtl[:amount]} /></div>
              <div class="w-[11.1rem]"><.input type="number" field={dtl[:balance]} /></div>
              <div class="w-[11.1rem]"><.input type="number" field={dtl[:match_amount]} /></div>
            </div>
          </.inputs_for>
        </div>

        <div class="text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400">
          <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
            <div class="detail-header w-[13.4rem]"><%= gettext("Bank") %></div>
            <div class="detail-header w-[13.4rem]"><%= gettext("City") %></div>
            <div class="detail-header w-[13.4rem]"><%= gettext("State") %></div>
            <div class="detail-header w-[13.4rem]"><%= gettext("Due Date") %></div>
            <div class="detail-header w-[13.4rem]"><%= gettext("Amount") %></div>
          </div>

          <.inputs_for :let={dtl} field={@form[:received_cheques]}>
            <div class={"flex flex-row flex-wrap #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
              <div class="w-[13.4rem]"><.input field={dtl[:bank]} /></div>
              <div class="w-[13.4rem]"><.input field={dtl[:city]} /></div>
              <div class="w-[13.4rem]"><.input field={dtl[:state]} /></div>
              <div class="w-[13.4rem]"><.input type="date" field={dtl[:due_date]} /></div>
              <div class="w-[13.4rem]"><.input type="number" field={dtl[:amount]} /></div>
              <div class="mt-2.5 text-rose-500">
                <.link
                  phx-click={:delete_cheque}
                  phx-value-index={dtl.index}
                  phx-target={@myself}
                  tabindex="-1"
                >
                  <.icon name="hero-trash-solid" class="h-5 w-5" />
                </.link>
                <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
              </div>
            </div>
          </.inputs_for>

          <div class="flex flex-row flex-wrap font-medium mt-2 tracking-tighter">
            <div class="w-2/12 text-orange-500">
              <.link phx-click={:add_cheque} phx-target={@myself}>
                <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Cheque") %>
              </.link>
            </div>
            <div class="w-[27.8rem]"></div>
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <.link phx-click={JS.exec("phx-remove", to: "#object-crud-modal")} class="blue_button">
            <%= gettext("Back") %>
          </.link>
          <.print_button
            :if={@live_action != :new}
            company={@current_company}
            entity="receipts"
            entity_id={@id}
            class="blue_button"
          />
          <.pre_print_button
            :if={@live_action != :new}
            company={@current_company}
            entity="receipts"
            entity_id={@id}
            class="blue_button"
          />
        </div>
      </.form>
    </div>
    """
  end
end
