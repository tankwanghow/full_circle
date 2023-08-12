defmodule FullCircleWeb.ReceiptLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{Accounting, ReceiveFund}
  alias FullCircle.ReceiveFund.{Receipt}
  # alias FullCircle.Accounting.TransactionMatcher
  # alias FullCircle.Sys
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["receipt_id"]
    to = Timex.today()
    from = Timex.shift(to, months: -1)

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(query: %{from: from, to: to})
     |> assign(query_match_trans: [])
     |> assign(
       settings:
         FullCircle.Sys.load_settings(
           "receipts",
           socket.assigns.current_company,
           socket.assigns.current_user
         )
     )}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Receipt"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Receipt,
          %Receipt{received_cheques: []},
          %{receipt_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      ReceiveFund.get_receipt!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      StdInterface.changeset(Receipt, object, %{}, socket.assigns.current_company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Receipt") <> " " <> object.receipt_no)
    |> assign(:form, to_form(cs))
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    socket = socket |> FullCircleWeb.Helpers.add_line(:receipt_details)
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    socket =
      socket
      |> FullCircleWeb.Helpers.delete_line(
        index,
        :receipt_details,
        &Receipt.compute_details_amount/1
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_cheque", _, socket) do
    socket = socket |> FullCircleWeb.Helpers.add_line(:received_cheques)
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_cheque", %{"index" => index}, socket) do
    socket =
      socket
      |> FullCircleWeb.Helpers.delete_line(
        index,
        :received_cheques,
        &Receipt.compute_cheques_amount/1
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("get_trans", %{"query" => %{"from" => from, "to" => to}}, socket) do
    ctid = Ecto.Changeset.fetch_field!(socket.assigns.form.source, :contact_id)

    trans =
      Accounting.query_transactions_for_matching(
        ctid,
        from,
        to,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply, socket |> assign(query: %{from: from, to: to}) |> assign(query_match_trans: trans)}
  end

  @impl true
  def handle_event("add_match_tran", %{"trans-id" => id}, socket) do
    match_tran =
      socket.assigns.query_match_trans
      |> Enum.find(fn x -> x.transaction_id == id end)

    match_tran =
      match_tran
      |> Map.merge(%{
        account_id: match_tran.account_id,
        entity: "receipts",
        all_matched_amount: match_tran.all_matched_amount,
        balance: 0.00,
        match_amount: Decimal.negate(match_tran.balance) |> Decimal.round(2)
      })

    socket =
      socket
      |> FullCircleWeb.Helpers.add_line(
        :transaction_matchers,
        match_tran,
        &Receipt.compute_match_transactions_amount/1
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_match_tran", %{"index" => index}, socket) do
    socket =
      socket
      |> FullCircleWeb.Helpers.delete_line(
        index,
        :transaction_matchers,
        &Receipt.compute_match_transactions_amount/1
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "contact_name"], "receipt" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "contact_name",
        "contact_id",
        &FullCircle.Accounting.get_contact_by_name/3
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
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "funds_account_name",
        "funds_account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "good_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]

    {detail, socket, good} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "good_name",
        "good_id",
        &FullCircle.Product.get_good_by_name/3
      )

    detail =
      Map.merge(detail, %{
        "account_name" => Util.attempt(good, :sales_account_name),
        "account_id" => Util.attempt(good, :sales_account_id),
        "tax_code_name" => Util.attempt(good, :sales_tax_code_name),
        "tax_code_id" => Util.attempt(good, :sales_tax_code_id),
        "tax_rate" => Util.attempt(good, :sales_tax_rate),
        "package_name" => Util.attempt(good, :package_name),
        "package_id" => Util.attempt(good, :package_id),
        "unit" => Util.attempt(good, :unit),
        "unit_multiplier" => Util.attempt(good, :unit_multiplier) || 0,
        "package_qty" => 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "package_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]
    terms = detail["package_name"]

    pack =
      FullCircle.Product.get_packaging_by_name(
        String.trim(terms),
        detail["good_id"]
      )

    detail =
      Map.merge(detail, %{
        "package_id" => Util.attempt(pack, :id) || nil,
        "unit_multiplier" => Util.attempt(pack, :unit_multiplier) || 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "account_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]

    {detail, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "account_name",
        "account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["receipt", "receipt_details", id, "tax_code_name"], "receipt" => params},
        socket
      ) do
    detail = params["receipt_details"][id]

    {detail, socket, taxcode} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "tax_code_name",
        "tax_code_id",
        &FullCircle.Accounting.get_tax_code_by_code/3
      )

    detail =
      Map.merge(detail, %{
        "tax_rate" => Util.attempt(taxcode, :rate) || 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("receipt_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["settings", id, "value"], "settings" => new_settings},
        socket
      ) do
    settings = socket.assigns.settings
    setting = Enum.find(settings, fn x -> x.id == id end)
    %{"value" => value} = Map.get(new_settings, id)
    setting = FullCircle.Sys.update_setting(setting, value)

    settings =
      Enum.reject(settings, fn x -> x.id == id end)
      |> Enum.concat([setting])
      |> Enum.sort_by(& &1.id)

    {:noreply,
     socket
     |> assign(settings: settings)}
  end

  @impl true
  def handle_event("validate", %{"receipt" => params}, socket) do
    validate(params, socket)
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
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/receipts/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Receipt created successfully."))}

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
    case ReceiveFund.update_receipt(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_receipt: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/receipts/#{obj.id}/edit"
         )
         |> put_flash(:info, gettext("Receipt updated successfully."))}

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
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
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

  defp found_in_matched_trans?(source, id) do
    Enum.any?(Ecto.Changeset.fetch_field!(source, :transaction_matchers), fn x ->
      x.transaction_id == id
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <%= Phoenix.HTML.Form.hidden_input(@form, :receipt_no) %>
        <div class="flex flex-row flex-nowarp">
          <div class="w-5/12 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :contact_id) %>
            <.input
              field={@form[:contact_name]}
              label={gettext("Customer")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="w-5/12 grow shrink">
            <%= Phoenix.HTML.Form.hidden_input(@form, :funds_account_id) %>
            <.input
              field={@form[:funds_account_name]}
              label={gettext("Funds Account")}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
          <div class="w-2/12 grow shrink">
            <.input
              field={@form[:funds_amount]}
              label={gettext("Funds Amount")}
              phx-debounce="blur"
              type="number"
              step="0.01"
            />
          </div>
          <div class="grow shrink w-2/12">
            <.input field={@form[:receipt_date]} label={gettext("Receipt Date")} type="date" />
          </div>
        </div>
        <div class="flex flex-row flex-nowrap">
          <div class="grow shrink w-10/12">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
          <div class="grow shrink w-2/12">
            <.input
              feedback={true}
              type="number"
              readonly
              field={@form[:receipt_balance]}
              label={gettext("Receipt Balance")}
            />
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <.link
            :if={Enum.any?(@form.source.changes) and @live_action != :new}
            navigate=""
            class="orange_button"
          >
            <%= gettext("Cancel") %>
          </.link>
          <a onclick="history.back();" class="blue_button"><%= gettext("Back") %></a>
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
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="receipts"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="receipts"
            doc_no={@form.data.receipt_no}
            company_id={@current_company.id}
          />
        </div>

        <div class="flex flex-row gap-2 flex-nowrap w-2/3 mx-auto text-center mt-5">
          <div
            id="receipt-cheques-tab"
            phx-click={
              JS.show(to: "#receipt-cheques")
              |> JS.add_class("active")
              |> JS.hide(to: "#match-trans")
              |> JS.hide(to: "#query-match-trans")
              |> JS.remove_class("active", to: "#match-trans-tab")
              |> JS.hide(to: "#receipt-details")
              |> JS.remove_class("active", to: "#receipt-details-tab")
            }
            class="active basis-1/3 tab"
          >
            <%= gettext("Cheques") %> =
            <span
              :if={!Decimal.eq?(Phoenix.HTML.Form.input_value(@form, :cheques_amount), 0)}
              class="font-normal text-green-700"
            >
              <%= Phoenix.HTML.Form.input_value(@form, :cheques_amount)
              |> Number.Delimit.number_to_delimited() %>
            </span>
          </div>

          <div
            id="match-trans-tab"
            phx-click={
              JS.hide(to: "#receipt-cheques")
              |> JS.remove_class("active", to: "#receipt-cheques-tab")
              |> JS.show(to: "#match-trans")
              |> JS.add_class("active")
              |> JS.hide(to: "#receipt-details")
              |> JS.remove_class("active", to: "#receipt-details-tab")
              |> JS.show(to: "#query-match-trans")
            }
            class="basis-1/3 tab"
          >
            <%= gettext("Matchers") %> =
            <span
              :if={!Decimal.eq?(Phoenix.HTML.Form.input_value(@form, :matched_amount), 0)}
              class="font-normal text-rose-700"
            >
              <%= Phoenix.HTML.Form.input_value(@form, :matched_amount)
              |> Decimal.abs()
              |> Number.Delimit.number_to_delimited() %>
            </span>
          </div>

          <div
            id="receipt-details-tab"
            phx-click={
              JS.hide(to: "#receipt-cheques")
              |> JS.remove_class("active", to: "#receipt-cheques-tab")
              |> JS.hide(to: "#match-trans")
              |> JS.hide(to: "#query-match-trans")
              |> JS.remove_class("active", to: "#match-trans-tab")
              |> JS.show(to: "#receipt-details")
              |> JS.add_class("active")
            }
            class="basis-1/3 tab"
          >
            <%= gettext("Details") %> =
            <span
              :if={!Decimal.eq?(Phoenix.HTML.Form.input_value(@form, :receipt_detail_amount), 0)}
              class="font-normal text-rose-700"
            >
              <%= Phoenix.HTML.Form.input_value(@form, :receipt_detail_amount)
              |> Number.Delimit.number_to_delimited() %>
            </span>
          </div>
        </div>

        <div
          id="receipt-cheques"
          class="text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
        >
          <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
            <div class="detail-header w-[16%]"><%= gettext("Bank") %></div>
            <div class="detail-header w-[16%]"><%= gettext("Cheque No") %></div>
            <div class="detail-header w-[16%]"><%= gettext("City") %></div>
            <div class="detail-header w-[17%]"><%= gettext("State") %></div>
            <div class="detail-header w-[16%]"><%= gettext("Due Date") %></div>
            <div class="detail-header w-[16%]"><%= gettext("Amount") %></div>
            <div class="w-[3%]"><%= gettext("") %></div>
          </div>

          <.inputs_for :let={dtl} field={@form[:received_cheques]}>
            <div class={"flex flex-row flex-wrap #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
              <div class="w-[16%]"><.input field={dtl[:bank]} /></div>
              <div class="w-[16%]"><.input field={dtl[:cheque_no]} /></div>
              <div class="w-[16%]"><.input field={dtl[:city]} /></div>
              <div class="w-[17%]"><.input field={dtl[:state]} /></div>
              <div class="w-[16%]"><.input type="date" field={dtl[:due_date]} /></div>
              <div class="w-[16%]">
                <.input phx-debounce="blur" type="number" step="0.01" field={dtl[:amount]} />
              </div>
              <div class="w-[3%] mt-2.5 text-rose-500">
                <.link phx-click={:delete_cheque} phx-value-index={dtl.index} tabindex="-1">
                  <.icon name="hero-trash-solid" class="h-5 w-5" />
                </.link>
                <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
              </div>
            </div>
          </.inputs_for>
          <div class="flex flex-row flex-wrap">
            <div class="w-[16%] text-orange-500 font-bold pt-2">
              <.link phx-click={:add_cheque}>
                <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Cheque") %>
              </.link>
            </div>
            <div class="w-[65%] pt-2 pr-2 font-semibold text-right">Cheques Total</div>
            <div class="w-[16%] font-semi bold">
              <.input type="number" readonly field={@form[:cheques_amount]} />
            </div>
          </div>
        </div>

        <.live_component
          module={FullCircleWeb.InvoiceLive.DetailComponent}
          id="receipt-details"
          klass="hidden text-center border bg-purple-100 mt-2 p-3 rounded-lg border-purple-400"
          settings={@settings}
          doc_name="receipts"
          detail_name={:receipt_details}
          form={@form}
          taxcodetype="saltaxcode"
          doc_good_amount={:receipt_good_amount}
          doc_tax_amount={:receipt_tax_amount}
          doc_detail_amount={:receipt_detail_amount}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div
          id="match-trans"
          class="hidden text-center border bg-green-100 mt-2 p-3 rounded-lg border-green-400"
        >
          <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
            <div class="detail-header w-[16%]"><%= gettext("Doc Date") %></div>
            <div class="detail-header w-[17%]"><%= gettext("Doc Type") %></div>
            <div class="detail-header w-[16%]"><%= gettext("Doc No") %></div>
            <div class="detail-header w-[16%]"><%= gettext("Amount") %></div>
            <div class="detail-header w-[16%]"><%= gettext("Balance") %></div>
            <div class="detail-header w-[16%]"><%= gettext("Match") %></div>
          </div>
          <.inputs_for :let={dtl} field={@form[:transaction_matchers]}>
            <div class="flex flex-row flex-wrap">
              <.input type="hidden" field={dtl[:transaction_id]} />
              <.input type="hidden" field={dtl[:all_matched_amount]} />
              <.input type="hidden" field={dtl[:account_id]} />
              <.input type="hidden" field={dtl[:entity]} />
              <div class="w-[16%]"><.input readonly field={dtl[:doc_date]} /></div>
              <div class="w-[17%]"><.input readonly field={dtl[:doc_type]} /></div>
              <div class="w-[16%]"><.input readonly field={dtl[:doc_no]} /></div>
              <div class="w-[16%]"><.input readonly type="number" field={dtl[:amount]} /></div>
              <div class="w-[16%]">
                <.input readonly type="number" field={dtl[:balance]} />
              </div>
              <div class="w-[16%]">
                <.input type="number" phx-debounce="blur" step="0.01" field={dtl[:match_amount]} />
              </div>
              <div class="w-[3%] mt-2.5 text-rose-500">
                <.link phx-click={:delete_match_tran} phx-value-index={dtl.index} tabindex="-1">
                  <.icon name="hero-trash-solid" class="h-5 w-5" />
                </.link>
                <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
              </div>
            </div>
          </.inputs_for>
          <div class="flex flex-row flex-wrap">
            <div class="w-[81%] pt-2 pr-2 font-semibold text-right">Matched Total</div>
            <div class="w-[16%] font-semi bold">
              <.input type="number" readonly field={@form[:matched_amount]} />
            </div>
          </div>
        </div>
      </.form>
    </div>

    <div
      id="query-match-trans"
      class="hidden w-8/12 mx-auto text-center border bg-teal-200 mt-2 p-3 rounded-lg border-teal-400"
    >
      <.form
        for={%{}}
        id="query-match-trans-form"
        phx-submit="get_trans"
        autocomplete="off"
        class="w-full"
      >
        Select Transactions from
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
        <.button><%= gettext("Query") %></.button>
      </.form>
      <div
        :if={Enum.count(@query_match_trans) == 0}
        class="mt-2 p-4 border rounded-lg border-orange-600 bg-orange-200 text-center"
      >
        <%= gettext("No Data!") %>
      </div>

      <div
        :if={Enum.count(@query_match_trans) > 0}
        class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter"
      >
        <div class="detail-header w-[13%]"><%= gettext("Doc Date") %></div>
        <div class="detail-header w-[13%]"><%= gettext("Doc Type") %></div>
        <div class="detail-header w-[14%]"><%= gettext("Doc No") %></div>
        <div class="detail-header w-[27%]"><%= gettext("Particulars") %></div>
        <div class="detail-header w-[15%]"><%= gettext("Amount") %></div>
        <div class="detail-header w-[15%]"><%= gettext("Balance") %></div>
        <div class="w-[3%]"></div>
      </div>
      <%= for obj <- @query_match_trans do %>
        <div class="flex flex-row flex-wrap">
          <div class="max-h-8 w-[13%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
            <%= obj.doc_date %>
          </div>
          <div class="max-h-8 w-[13%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
            <%= obj.doc_type %>
          </div>
          <div class="max-h-8 w-[14%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
            <%= obj.doc_no %>
          </div>
          <div class="max-h-8 w-[27%] border rounded bg-blue-200 border-blue-400 px-2 py-1 overflow-clip">
            <%= obj.particulars %>
          </div>
          <div class="max-h-8 w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
            <%= obj.amount |> Number.Delimit.number_to_delimited() %>
          </div>
          <div class="max-h-8 w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
            <%= obj.balance |> Number.Delimit.number_to_delimited() %>
          </div>
          <div
            :if={
              !found_in_matched_trans?(@form.source, obj.transaction_id) and
                Decimal.positive?(obj.balance)
            }
            class="w-[3%] text-green-500 cursor-pointer"
          >
            <.link phx-click={:add_match_tran} phx-value-trans-id={obj.transaction_id} tabindex="-1">
              <.icon name="hero-plus-circle-solid" class="h-7 w-7" />
            </.link>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
