defmodule FullCircleWeb.BankReconciliationLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankReconciliation
  alias FullCircle.BankReconciliation.LlmParser
  alias FullCircle.JournalEntry

  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :view_bank_reconciliation,
         socket.assigns.current_company
       ) do
      llm_settings = load_llm_settings(socket)

      socket =
        socket
        |> assign(page_title: gettext("Bank Reconciliation"))
        |> assign(search: %{name: "", f_date: "", t_date: ""})
        |> assign(statement_lines: [])
        |> assign(book_transactions: [])
        |> assign(summary: nil)
        |> assign(account: nil)
        |> assign(selected_stmt_ids: MapSet.new())
        |> assign(selected_txn_ids: MapSet.new())
        |> assign(suggested_matches: [])
        |> assign(queried?: false)
        |> assign(finalized?: false)
        |> assign(can_finalize?: FullCircle.Authorization.can?(socket.assigns.current_user, :finalize_bank_reconciliation, socket.assigns.current_company))
        |> assign(processing_csv: false, csv_task: nil)
        |> assign(processing_ai_match: false, ai_match_task: nil)
        |> assign(book_entry_mode: false, book_entry_lines: [], book_entry_contra: "")
        |> assign(llm_settings: llm_settings)
        |> allow_upload(:csv_file,
          accept: ~w(.csv .pdf),
          max_file_size: 10_000_000,
          progress: &handle_progress/3,
          auto_upload: true
        )

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Not authorized."))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"] || %{}

    name = params["name"] || ""
    f_date = params["f_date"] || ""
    t_date = params["t_date"] || ""

    socket = socket |> assign(search: %{name: name, f_date: f_date, t_date: t_date})

    {:noreply,
     if String.trim(name) != "" and f_date != "" and t_date != "" do
       load_data(socket, name, f_date, t_date)
     else
       socket
     end}
  end

  @impl true
  def handle_event("changed", _, socket), do: {:noreply, socket}

  @impl true
  def handle_event("query", %{"search" => %{"name" => name, "f_date" => f_date, "t_date" => t_date}}, socket) do
    qry = %{
      "search[name]" => name,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/bank_reconciliation?#{URI.encode_query(qry)}"

    {:noreply, push_navigate(socket, to: url)}
  end

  @impl true
  def handle_event("toggle_stmt", %{"id" => id}, socket) do
    selected = toggle_set(socket.assigns.selected_stmt_ids, id)
    {:noreply, assign(socket, selected_stmt_ids: selected)}
  end

  @impl true
  def handle_event("toggle_txn", %{"id" => id}, socket) do
    selected = toggle_set(socket.assigns.selected_txn_ids, id)
    {:noreply, assign(socket, selected_txn_ids: selected)}
  end

  @impl true
  def handle_event("clear_selection", _, socket) do
    {:noreply, assign(socket, selected_stmt_ids: MapSet.new(), selected_txn_ids: MapSet.new())}
  end

  @impl true
  def handle_event("match_selected", _, socket) do
    stmt_ids = MapSet.to_list(socket.assigns.selected_stmt_ids)
    txn_ids = MapSet.to_list(socket.assigns.selected_txn_ids)

    # Allow normal match (both sides) or bank-to-bank match (stmt only, sum = 0)
    bank_to_bank? = stmt_ids != [] and txn_ids == [] and stmt_sum_zero?(stmt_ids, socket)

    if (stmt_ids != [] and txn_ids != []) or bank_to_bank? do
      old_stmt_groups =
        socket.assigns.statement_lines
        |> Enum.filter(&(&1.id in stmt_ids and &1.match_group_id))
        |> Enum.map(& &1.match_group_id)

      old_txn_groups =
        socket.assigns.book_transactions
        |> Enum.filter(&(&1.id in txn_ids and &1.match_group_id))
        |> Enum.map(& &1.match_group_id)

      old_groups = Enum.uniq(old_stmt_groups ++ old_txn_groups)

      case BankReconciliation.rematch_group(stmt_ids, txn_ids, old_groups) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(selected_stmt_ids: MapSet.new(), selected_txn_ids: MapSet.new(), suggested_matches: [])
           |> reload_data()
           |> put_flash(:info, gettext("Match confirmed."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to confirm match."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Select at least one item on each side."))}
    end
  end

  @impl true
  def handle_event("dismiss_selected", _, socket) do
    stmt_ids = MapSet.to_list(socket.assigns.selected_stmt_ids)

    if stmt_ids != [] do
      BankReconciliation.dismiss_statement_lines(stmt_ids)

      {:noreply,
       socket
       |> assign(selected_stmt_ids: MapSet.new(), selected_txn_ids: MapSet.new())
       |> reload_data()
       |> put_flash(:info, gettext("Statement lines dismissed."))}
    else
      {:noreply, put_flash(socket, :error, gettext("Select statement lines to dismiss."))}
    end
  end

  @impl true
  def handle_event("start_book_entry", _, socket) do
    stmt_ids = MapSet.to_list(socket.assigns.selected_stmt_ids)

    lines =
      socket.assigns.statement_lines
      |> Enum.filter(&(&1.id in stmt_ids and is_nil(&1.match_group_id)))
      |> Enum.map(fn sl ->
        %{
          id: sl.id,
          date: sl.statement_date,
          description: sl.description,
          amount: sl.amount,
          particulars: sl.description
        }
      end)

    if lines != [] do
      {:noreply, assign(socket, book_entry_mode: true, book_entry_lines: lines, book_entry_contra: "")}
    else
      {:noreply, put_flash(socket, :error, gettext("Select unmatched statement lines first."))}
    end
  end

  @impl true
  def handle_event("cancel_book_entry", _, socket) do
    {:noreply, assign(socket, book_entry_mode: false, book_entry_lines: [], book_entry_contra: "")}
  end

  @impl true
  def handle_event("update_book_entry", %{"contra" => contra} = params, socket) do
    lines =
      socket.assigns.book_entry_lines
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        particulars = params["particulars_#{idx}"] || line.particulars
        %{line | particulars: particulars}
      end)

    {:noreply, assign(socket, book_entry_contra: contra, book_entry_lines: lines)}
  end

  @impl true
  def handle_event("confirm_book_entry", %{"contra" => contra} = params, socket) do
    lines =
      socket.assigns.book_entry_lines
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        particulars = params["particulars_#{idx}"] || line.particulars
        %{line | particulars: particulars}
      end)

    company = socket.assigns.current_company
    user = socket.assigns.current_user
    account = socket.assigns.account

    contra_trimmed = String.trim(contra)
    contra_account =
      if contra_trimmed != "",
        do: FullCircle.Accounting.get_account_by_name(contra_trimmed, company, user)

    cond do
      contra_trimmed == "" ->
        {:noreply, put_flash(socket, :error, gettext("Contra account is required."))}

      is_nil(contra_account) ->
        {:noreply, put_flash(socket, :error, "#{gettext("Account not found")}: #{contra_trimmed}")}

      true ->
        # Sum all lines into one journal entry, use latest date
        total = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.amount, &2))
        journal_date = lines |> Enum.map(& &1.date) |> Enum.max(Date)
        particulars = lines |> Enum.map(& &1.particulars) |> Enum.uniq() |> Enum.join("; ")
        stmt_ids = Enum.map(lines, & &1.id)

        attrs = %{
          "journal_date" => Date.to_iso8601(journal_date),
          "company_id" => company.id,
          "transactions" => %{
            "0" => %{
              "account_name" => account.name,
              "account_id" => account.id,
              "amount" => Decimal.to_string(total),
              "particulars" => particulars
            },
            "1" => %{
              "account_name" => contra_account.name,
              "account_id" => contra_account.id,
              "amount" => Decimal.to_string(Decimal.negate(total)),
              "particulars" => particulars
            }
          }
        }

        result =
          case JournalEntry.create_journal(attrs, company, user) do
            {:ok, %{create_journal: journal}} ->
              txn = BankReconciliation.find_journal_transaction(journal.id, account.id)

              if txn do
                BankReconciliation.confirm_group_match(stmt_ids, [txn.id])
              end

              {:ok, journal}

            {:error, _step, changeset, _} ->
              {:error, changeset}

            :not_authorise ->
              {:error, :not_authorise}
          end

        socket =
          socket
          |> assign(
            book_entry_mode: false,
            book_entry_lines: [],
            book_entry_contra: "",
            selected_stmt_ids: MapSet.new(),
            selected_txn_ids: MapSet.new()
          )
          |> reload_data()

        case result do
          {:ok, _} ->
            {:noreply, put_flash(socket, :info, "#{gettext("Journal entry created and matched")} (#{length(lines)} #{gettext("lines")})")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to create journal entry."))}
        end
    end
  end

  @impl true
  def handle_event("unmatch_group", %{"group-id" => group_id}, socket) do
    case BankReconciliation.unmatch_group(group_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload_data()
         |> put_flash(:info, gettext("Match group removed."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to unmatch."))}
    end
  end

  @impl true
  def handle_event("auto_match", _, socket) do
    if socket.assigns.account do
      matches =
        BankReconciliation.auto_match(
          socket.assigns.account.id,
          socket.assigns.current_company.id,
          Date.from_iso8601!(socket.assigns.search.f_date),
          Date.from_iso8601!(socket.assigns.search.t_date)
        )

      if matches == [] do
        {:noreply, put_flash(socket, :info, gettext("No auto-matches found."))}
      else
        {:noreply, assign(socket, suggested_matches: matches)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("ai_match", _, socket) do
    if socket.assigns.account do
      account_id = socket.assigns.account.id
      company_id = socket.assigns.current_company.id
      from = Date.from_iso8601!(socket.assigns.search.f_date)
      to = Date.from_iso8601!(socket.assigns.search.t_date)
      llm_settings = socket.assigns.llm_settings

      task =
        Task.async(fn ->
          BankReconciliation.ai_match(account_id, company_id, from, to, llm_settings)
        end)

      {:noreply, assign(socket, processing_ai_match: true, ai_match_task: task)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_all_suggested", _, socket) do
    case BankReconciliation.confirm_auto_matches(socket.assigns.suggested_matches) do
      {:ok, _} ->
        count = length(socket.assigns.suggested_matches)

        {:noreply,
         socket
         |> assign(suggested_matches: [])
         |> reload_data()
         |> put_flash(:info, "#{count} #{gettext("matches confirmed.")}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to confirm matches."))}
    end
  end

  @impl true
  def handle_event("cancel_suggested", _, socket) do
    {:noreply, assign(socket, suggested_matches: [])}
  end

  @impl true
  def handle_event("delete_statement", _, socket) do
    if socket.assigns.account do
      case BankReconciliation.delete_statement_lines(
             socket.assigns.account.id,
             socket.assigns.current_company.id,
             Date.from_iso8601!(socket.assigns.search.f_date),
             Date.from_iso8601!(socket.assigns.search.t_date)
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> reload_data()
           |> put_flash(:info, gettext("Statement lines deleted."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete statement lines."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("finalize_period", _, socket) do
    if socket.assigns.account do
      if FullCircle.Authorization.can?(
           socket.assigns.current_user,
           :finalize_bank_reconciliation,
           socket.assigns.current_company
         ) do
        from = Date.from_iso8601!(socket.assigns.search.f_date)
        to = Date.from_iso8601!(socket.assigns.search.t_date)

        BankReconciliation.finalize_period(
          socket.assigns.account.id,
          socket.assigns.current_company.id,
          from,
          to
        )

        {:noreply,
         socket
         |> assign(finalized?: true)
         |> put_flash(:info, gettext("Period finalized. You can now print the report."))}
      else
        {:noreply, put_flash(socket, :error, gettext("Not authorized to finalize."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", _, socket), do: {:noreply, socket}

  defp stmt_sum_zero?(stmt_ids, socket) do
    total =
      socket.assigns.statement_lines
      |> Enum.filter(&(&1.id in stmt_ids))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))

    Decimal.eq?(total, 0)
  end

  def handle_progress(:csv_file, entry, socket) do
    if entry.done? do
      is_pdf = String.ends_with?(String.downcase(entry.client_name), ".pdf")

      {tmp_path, llm_settings, account_id, _company_id} =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          ext = if is_pdf, do: ".pdf", else: ".csv"
          tmp = Path.join(System.tmp_dir!(), "bank_#{Ecto.UUID.generate()}#{ext}")
          File.cp!(path, tmp)
          {:ok, {tmp, socket.assigns.llm_settings, socket.assigns.account && socket.assigns.account.id, socket.assigns.current_company.id}}
        end)

      if account_id do
        task =
          Task.async(fn ->
            result =
              if is_pdf do
                LlmParser.parse_pdf(tmp_path, llm_settings)
              else
                LlmParser.parse(tmp_path, llm_settings)
              end

            File.rm(tmp_path)
            result
          end)

        {:noreply, assign(socket, processing_csv: true, csv_task: task)}
      else
        File.rm(tmp_path)
        {:noreply, put_flash(socket, :error, gettext("Query an account first."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    alias FullCircle.BankReconciliation.LlmClient

    cond do
      # CSV parsing task result
      socket.assigns.csv_task && ref == socket.assigns.csv_task.ref ->
        case result do
          {:ok, format, lines, usage, balances} ->
            {count, _} =
              BankReconciliation.import_statement(
                socket.assigns.account.id,
                socket.assigns.current_company.id,
                lines,
                format
              )

            if balances.opening_balance || balances.closing_balance do
              BankReconciliation.save_statement_balances(
                socket.assigns.current_company.id,
                socket.assigns.account.id,
                socket.assigns.search.f_date,
                socket.assigns.search.t_date,
                balances
              )
            end

            usage_str = if usage, do: " (#{LlmClient.format_usage(usage)})", else: ""

            {:noreply,
             socket
             |> assign(processing_csv: false, csv_task: nil)
             |> reload_data()
             |> put_flash(:info, "#{count} #{gettext("lines imported from")} #{format}.#{usage_str}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(processing_csv: false, csv_task: nil)
             |> put_flash(:error, reason)}
        end

      # AI match task result
      socket.assigns.ai_match_task && ref == socket.assigns.ai_match_task.ref ->
        case result do
          {:ok, matches, usage} when matches != [] ->
            usage_str = if usage, do: " (#{LlmClient.format_usage(usage)})", else: ""

            {:noreply,
             socket
             |> assign(processing_ai_match: false, ai_match_task: nil, suggested_matches: matches)
             |> put_flash(:info, "#{length(matches)} #{gettext("AI matches found.")}#{usage_str}")}

          {:ok, _, usage} ->
            usage_str = if usage, do: " (#{LlmClient.format_usage(usage)})", else: ""

            {:noreply,
             socket
             |> assign(processing_ai_match: false, ai_match_task: nil)
             |> put_flash(:info, "#{gettext("No AI matches found.")}#{usage_str}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(processing_ai_match: false, ai_match_task: nil)
             |> put_flash(:error, reason)}
        end

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     socket
     |> assign(processing_csv: false, csv_task: nil)
     |> put_flash(:error, "CSV processing failed: #{inspect(reason)}")}
  end

  defp load_data(socket, name, f_date, t_date) do
    account =
      BankReconciliation.get_account_by_name(
        name,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    if account do
      from = Date.from_iso8601!(f_date)
      to = Date.from_iso8601!(t_date)
      company = socket.assigns.current_company

      stmts = BankReconciliation.list_statement_lines(account.id, company.id, from, to)
      txns = BankReconciliation.list_book_transactions(account, from, to, company)
      summary = BankReconciliation.reconciliation_summary(account.id, company.id, from, to)

      # Book balances use the user-specified from_date (not effective)
      book_opening = BankReconciliation.book_opening_balance(account.id, company.id, from)
      book_closing = BankReconciliation.book_closing_balance(account.id, company.id, to)

      stmt_balances = BankReconciliation.load_statement_balances(company.id, account.id, f_date, t_date)
      finalized? = BankReconciliation.is_finalized?(account.id, company.id, from, to)

      summary =
        Map.merge(summary, %{
          book_opening: book_opening,
          book_closing: book_closing,
          stmt_opening: stmt_balances.opening_balance,
          stmt_closing: stmt_balances.closing_balance
        })

      socket
      |> assign(
        account: account,
        statement_lines: stmts,
        book_transactions: txns,
        summary: summary,
        queried?: true,
        finalized?: finalized?,
        selected_stmt_ids: MapSet.new(),
        selected_txn_ids: MapSet.new(),
        suggested_matches: []
      )
    else
      socket
      |> assign(account: nil, statement_lines: [], book_transactions: [], summary: nil, queried?: true)
      |> put_flash(:error, gettext("Account not found."))
    end
  end

  defp reload_data(socket) do
    if socket.assigns.account do
      load_data(socket, socket.assigns.search.name, socket.assigns.search.f_date, socket.assigns.search.t_date)
    else
      socket
    end
  end

  defp toggle_set(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp suggested_stmt_ids(suggested_matches) do
    Enum.reduce(suggested_matches, MapSet.new(), fn {stmt_ids, _txn_ids, _score}, acc ->
      Enum.reduce(stmt_ids, acc, &MapSet.put(&2, &1))
    end)
  end

  defp suggested_txn_ids(suggested_matches) do
    Enum.reduce(suggested_matches, MapSet.new(), fn {_stmt_ids, txn_ids, _score}, acc ->
      Enum.reduce(txn_ids, acc, &MapSet.put(&2, &1))
    end)
  end


  defp format_amount(amount) do
    if amount, do: Number.Delimit.number_to_delimited(amount), else: ""
  end


  defp format_date(date) do
    FullCircleWeb.Helpers.format_date(date)
  end

  defp selection_total(ids, items, id_field) do
    items
    |> Enum.filter(&(Map.get(&1, id_field) in ids))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp load_llm_settings(socket) do
    defaults = %{
      "llm-provider" => "none",
      "llm-endpoint" => "",
      "llm-model" => "",
      "llm-api-key" => ""
    }

    saved = FullCircle.Sys.get_company_settings(socket.assigns.current_company, "llm")
    Map.merge(defaults, saved)
  end

  @impl true
  def render(assigns) do
    suggested_stmt = suggested_stmt_ids(assigns.suggested_matches)
    suggested_txn = suggested_txn_ids(assigns.suggested_matches)

    stmt_sel_total = selection_total(assigns.selected_stmt_ids, assigns.statement_lines, :id)
    txn_sel_total = selection_total(assigns.selected_txn_ids, assigns.book_transactions, :id)

    bank_to_bank? =
      MapSet.size(assigns.selected_stmt_ids) >= 2 and
        MapSet.size(assigns.selected_txn_ids) == 0 and
        Decimal.eq?(stmt_sel_total, 0)

    assigns =
      assign(assigns,
        suggested_stmt: suggested_stmt,
        suggested_txn: suggested_txn,
        stmt_sel_total: stmt_sel_total,
        txn_sel_total: txn_sel_total,
        bank_to_bank?: bank_to_bank?
      )

    ~H"""
    <div class="w-[98%] mx-auto mb-5">
      <p class="text-2xl text-center font-medium">{@page_title}</p>

      <%!-- Search Form --%>
      <div class="border rounded bg-purple-200 text-center p-2 mb-2">
        <.form for={%{}} id="search-form" phx-change="changed" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter gap-1">
            <div class="col-span-4">
              <.input
                label={gettext("Bank Account")}
                id="search_name"
                name="search[name]"
                value={@search.name}
                phx-hook="tributeAutoComplete"
                url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("To")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-2 mt-6">
              <.button>{gettext("Query")}</.button>
            </div>
            <div class="col-span-2 mt-6" :if={@queried? and @account}>
              <label :if={!@processing_csv} class="inline-block bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium px-3 py-1.5 rounded cursor-pointer">
                {gettext("Upload CSV/PDF")}, {FullCircle.BankReconciliation.LlmClient.active_model(@llm_settings)}
                <.live_file_input upload={@uploads.csv_file} class="hidden" />
              </label>
              <div :if={@processing_csv} class="inline-flex items-center gap-2 bg-amber-100 text-amber-800 text-sm font-medium px-3 py-1.5 rounded">
                <svg class="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                {FullCircle.BankReconciliation.LlmClient.active_model(@llm_settings)} {gettext("is processing...")}
              </div>
            </div>
          </div>
        </.form>
      </div>

      <%!-- Summary Bar --%>
      <details :if={@summary} class="border rounded bg-cyan-100 mb-2 text-sm tracking-tighter">
        <summary class="cursor-pointer p-2 font-semibold flex items-center justify-between">
          <span>{gettext("Summary")}</span>
          <span class="flex gap-4 font-normal text-xs">
            <span>
              {gettext("Diff")}:
              <span class={if(Decimal.eq?(@summary.difference, 0), do: "text-green-700 font-bold", else: "text-red-600 font-bold")}>
                {format_amount(@summary.difference)}
              </span>
            </span>
            <span>
              {gettext("Unmatched")}:
              <span class="text-orange-600">{gettext("Stmt")}: {@summary.statement_unmatched} | {gettext("Book")}: {@summary.book_unreconciled}</span>
            </span>
          </span>
        </summary>
        <div class="p-2 pt-0">
          <div class="grid grid-cols-4 text-center gap-1">
            <div class="font-semibold"></div>
            <div class="font-semibold">{gettext("Statement")}</div>
            <div class="font-semibold">{gettext("Book")}</div>
            <div class="font-semibold">{gettext("Diff")}</div>

            <div :if={@summary.stmt_opening || @summary.book_opening} class="font-semibold text-right pr-2">{gettext("Opening Bal")}</div>
            <div :if={@summary.stmt_opening || @summary.book_opening}>{if @summary.stmt_opening, do: format_amount(@summary.stmt_opening), else: "-"}</div>
            <div :if={@summary.stmt_opening || @summary.book_opening}>{format_amount(@summary.book_opening)}</div>
            <div :if={@summary.stmt_opening || @summary.book_opening}>
              {if @summary.stmt_opening, do: format_amount(Decimal.sub(@summary.stmt_opening, @summary.book_opening)), else: "-"}
            </div>

            <div class="font-semibold text-right pr-2">{gettext("+ve")}</div>
            <div>{format_amount(@summary.statement_total_pos)}</div>
            <div>{format_amount(@summary.book_total_pos)}</div>
            <div>{format_amount(@summary.diff_pos)}</div>

            <div class="font-semibold text-right pr-2">{gettext("-ve")}</div>
            <div>{format_amount(@summary.statement_total_neg)}</div>
            <div>{format_amount(@summary.book_total_neg)}</div>
            <div>{format_amount(@summary.diff_neg)}</div>

            <div :if={@summary.stmt_closing || @summary.book_closing} class="font-semibold text-right pr-2">{gettext("Closing Bal")}</div>
            <div :if={@summary.stmt_closing || @summary.book_closing}>{if @summary.stmt_closing, do: format_amount(@summary.stmt_closing), else: "-"}</div>
            <div :if={@summary.stmt_closing || @summary.book_closing}>{format_amount(@summary.book_closing)}</div>
            <div :if={@summary.stmt_closing || @summary.book_closing}>
              {if @summary.stmt_closing, do: format_amount(Decimal.sub(@summary.stmt_closing, @summary.book_closing)), else: "-"}
            </div>

            <div class="font-semibold text-right pr-2">{gettext("Difference")}</div>
            <div></div>
            <div></div>
            <div class={if(Decimal.eq?(@summary.difference, 0), do: "text-green-700 font-bold", else: "text-red-600 font-bold")}>
              {format_amount(@summary.difference)}
            </div>
          </div>
          <div class="grid grid-cols-3 text-center mt-1 border-t border-cyan-300 pt-1">
            <div>
              <span class="font-semibold">{gettext("Stmt Matched")}:</span>
              {@summary.statement_matched}/{@summary.statement_count}
            </div>
            <div>
              <span class="font-semibold">{gettext("Book Reconciled")}:</span>
              {@summary.book_reconciled}/{@summary.book_count}
            </div>
            <div>
              <span class="font-semibold">{gettext("Unmatched")}:</span>
              <span class="text-orange-600">{gettext("Stmt")}: {@summary.statement_unmatched} | {gettext("Book")}: {@summary.book_unreconciled}</span>
            </div>
          </div>
        </div>
      </details>

      <%!-- Action Buttons + Selection Info --%>
      <div :if={@queried? and @account} class="flex items-center gap-2 mb-2 flex-wrap">
        <button phx-click="auto_match" class="bg-blue-500 text-white px-3 py-1 rounded text-sm hover:bg-blue-600">
          {gettext("Auto-Match")}
        </button>
        <button
          :if={@llm_settings["llm-provider"] not in [nil, "", "none"] and !@processing_ai_match}
          phx-click="ai_match"
          class="bg-purple-500 text-white px-3 py-1 rounded text-sm hover:bg-purple-600"
        >
          {gettext("AI Match")}
        </button>
        <div :if={@processing_ai_match} class="inline-flex items-center gap-2 bg-purple-100 text-purple-800 text-sm font-medium px-3 py-1 rounded">
          <svg class="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          {FullCircle.BankReconciliation.LlmClient.active_model(@llm_settings)} {gettext("is matching...")}
        </div>
        <button
          :if={MapSet.size(@selected_stmt_ids) > 0 and MapSet.size(@selected_txn_ids) > 0}
          phx-click="match_selected"
          class="bg-green-500 text-white px-3 py-1 rounded text-sm hover:bg-green-600"
        >
          {gettext("Match Selected")}
          ({MapSet.size(@selected_stmt_ids)} stmt + {MapSet.size(@selected_txn_ids)} txn)
        </button>
        <button
          :if={@bank_to_bank?}
          phx-click="match_selected"
          class="bg-amber-500 text-white px-3 py-1 rounded text-sm hover:bg-amber-600"
        >
          {gettext("Bank-to-Bank Match")}
          ({MapSet.size(@selected_stmt_ids)} {gettext("lines, sum = 0")})
        </button>
        <button
          :if={MapSet.size(@selected_stmt_ids) > 0 and MapSet.size(@selected_txn_ids) == 0 and not @bank_to_bank?}
          phx-click="dismiss_selected"
          data-confirm={gettext("Dismiss selected statement lines? They will be marked as matched and won't carry forward.")}
          class="bg-gray-600 text-white px-3 py-1 rounded text-sm hover:bg-gray-700"
        >
          {gettext("Dismiss")}
          ({MapSet.size(@selected_stmt_ids)})
        </button>
        <button
          :if={MapSet.size(@selected_stmt_ids) > 0 and MapSet.size(@selected_txn_ids) == 0}
          phx-click="start_book_entry"
          class="bg-indigo-500 text-white px-3 py-1 rounded text-sm hover:bg-indigo-600"
        >
          {gettext("Book Entry")}
          ({MapSet.size(@selected_stmt_ids)})
        </button>
        <span
          :if={MapSet.size(@selected_stmt_ids) > 0 or MapSet.size(@selected_txn_ids) > 0}
          class="text-xs tracking-tighter"
        >
          Stmt: <span class="font-semibold">{format_amount(@stmt_sel_total)}</span>
          | Txn: <span class="font-semibold">{format_amount(@txn_sel_total)}</span>
          | Diff: <span class={[
            "font-semibold",
            if(Decimal.eq?(Decimal.sub(@stmt_sel_total, @txn_sel_total), 0), do: "text-green-700", else: "text-red-600")
          ]}>{format_amount(Decimal.sub(@stmt_sel_total, @txn_sel_total))}</span>
        </span>
        <button
          :if={MapSet.size(@selected_stmt_ids) > 0 or MapSet.size(@selected_txn_ids) > 0}
          phx-click="clear_selection"
          class="bg-gray-400 text-white px-2 py-1 rounded text-xs hover:bg-gray-500"
        >
          {gettext("Clear")}
        </button>
        <button
          :if={@suggested_matches != []}
          phx-click="confirm_all_suggested"
          class="bg-green-600 text-white px-3 py-1 rounded text-sm hover:bg-green-700"
        >
          {gettext("Confirm All Suggestions")} ({length(@suggested_matches)})
        </button>
        <button
          :if={@suggested_matches != []}
          phx-click="cancel_suggested"
          class="bg-gray-500 text-white px-2 py-1 rounded text-xs hover:bg-gray-600"
        >
          {gettext("Cancel Suggestions")}
        </button>
        <button
          :if={not is_nil(@account) and @can_finalize?}
          phx-click="finalize_period"
          data-confirm={if @finalized?, do: gettext("Re-finalize this period? The snapshot will be overwritten."), else: nil}
          class={[
            "px-3 py-1 rounded text-sm ml-auto",
            if(@finalized?, do: "bg-amber-500 hover:bg-amber-600 text-white", else: "bg-teal-500 hover:bg-teal-600 text-white")
          ]}
        >
          {if @finalized?, do: gettext("Re-Finalize"), else: gettext("Finalize")}
        </button>
        <a
          :if={not is_nil(@account) and @finalized?}
          href={~p"/companies/#{@current_company.id}/bank_reconciliation/print?name=#{@search.name}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"}
          target="_blank"
          class="bg-teal-500 text-white px-3 py-1 rounded text-sm hover:bg-teal-600"
        >
          {gettext("Print")}
        </a>
        <button
          :if={@statement_lines != []}
          phx-click="delete_statement"
          data-confirm={gettext("Delete all imported statement lines for this period?")}
          class="bg-red-500 text-white px-3 py-1 rounded text-sm hover:bg-red-600"
        >
          {gettext("Delete Statement")}
        </button>
      </div>

      <%!-- Book Entry Form --%>
      <div :if={@book_entry_mode} class="border-2 border-indigo-400 rounded bg-indigo-50 p-3 mb-2">
        <div class="flex items-center justify-between mb-2">
          <span class="font-semibold text-sm">{gettext("Create Book Entries")} ({length(@book_entry_lines)} {gettext("lines")})</span>
          <button phx-click="cancel_book_entry" class="text-gray-500 hover:text-gray-700 text-sm">{gettext("Cancel")}</button>
        </div>
        <.form for={%{}} phx-change="update_book_entry" phx-submit="confirm_book_entry" autocomplete="off">
          <div class="flex items-end gap-2 mb-2">
            <div class="flex-1">
              <label class="block text-xs font-medium mb-0.5">{gettext("Contra Account")}</label>
              <input
                type="text"
                name="contra"
                id="book_entry_contra"
                value={@book_entry_contra}
                placeholder={gettext("e.g. Bank Charges")}
                phx-hook="tributeAutoComplete"
                phx-debounce="500"
                url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
                class="w-full border border-gray-300 rounded px-2 py-1 text-sm"
              />
            </div>
            <button type="submit" phx-disable-with={gettext("Creating...")} class="bg-indigo-600 text-white px-4 py-1 rounded text-sm hover:bg-indigo-700">
              {gettext("Create & Match")}
            </button>
          </div>
          <div class="text-xs text-gray-500 mb-1">
            {gettext("Each line creates a journal entry: bank account")} ↔ {gettext("contra account")}
          </div>
          <table class="w-full text-xs">
            <thead>
              <tr class="bg-indigo-100">
                <th class="px-2 py-1 text-left">{gettext("Date")}</th>
                <th class="px-2 py-1 text-left">{gettext("Description")}</th>
                <th class="px-2 py-1 text-left">{gettext("Particulars")}</th>
                <th class="px-2 py-1 text-right">{gettext("Amount")}</th>
              </tr>
            </thead>
            <tbody>
              <%= for {line, idx} <- Enum.with_index(@book_entry_lines) do %>
                <tr class="border-b border-indigo-200">
                  <td class="px-2 py-1">{format_date(line.date)}</td>
                  <td class="px-2 py-1 truncate max-w-[300px]" title={line.description}>{line.description}</td>
                  <td class="px-2 py-1">
                    <input
                      type="text"
                      name={"particulars_#{idx}"}
                      value={line.particulars}
                      phx-debounce="500"
                      class="w-full border border-gray-300 rounded px-1 py-0.5 text-xs"
                    />
                  </td>
                  <td class="px-2 py-1 text-right">{format_amount(line.amount)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </.form>
      </div>

      <%!-- Two-Panel Layout --%>
      <div :if={@queried? and @account} class="grid grid-cols-2 gap-2" id="recon-panels">
        <%!-- Left: Bank Statement Lines --%>
        <div>
          <div class="font-semibold text-center bg-amber-200 rounded p-1 mb-1 text-sm">
            {gettext("Bank Statement")} ({length(@statement_lines)})
          </div>
          <div class="font-medium flex flex-row text-center tracking-tighter text-xs mb-1">
            <div class="w-[3%]"></div>
            <div class="w-[13%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Date")}</div>
            <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Chq#")}</div>
            <div class="w-[39%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Description")}</div>
            <div class="w-[17%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Amount")}</div>
            <div class="w-[18%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Status")}</div>
          </div>
          <div class="max-h-[65vh] overflow-y-auto">
            <%= for line <- @statement_lines do %>
              <% matched? = not is_nil(line.match_group_id) %>
              <% suggested? = MapSet.member?(@suggested_stmt, line.id) %>
              <% selected? = MapSet.member?(@selected_stmt_ids, line.id) %>
              <div
                phx-click={unless matched?, do: "toggle_stmt"}
                phx-value-id={line.id}
                class={[
                  "flex flex-row text-center tracking-tighter text-xs",
                  not matched? && "cursor-pointer",
                  matched? && !selected? && "bg-green-100",
                  suggested? && !matched? && !selected? && "bg-yellow-100",
                  selected? && "ring-2 ring-blue-500 bg-blue-50",
                  not matched? && not suggested? && not selected? && "bg-red-50 hover:bg-red-100"
                ]}
              >
                <div class="w-[3%] py-0.5">
                  <input
                    :if={not matched?}
                    type="checkbox"
                    checked={selected?}
                    class="rounded border-gray-400"
                    phx-click="toggle_stmt"
                    phx-value-id={line.id}
                  />
                </div>
                <div class="w-[13%] border rounded border-gray-300 px-1 py-0.5">{format_date(line.statement_date)}</div>
                <div class="w-[10%] border rounded border-gray-300 px-1 py-0.5 truncate">{line.cheque_no}</div>
                <div class="w-[39%] border rounded border-gray-300 px-1 py-0.5 text-left truncate" title={line.description <> if(line.reference, do: " | " <> line.reference, else: "")}>{line.description}</div>
                <div class="w-[17%] border rounded border-gray-300 px-1 py-0.5">
                  {format_amount(line.amount)}
                </div>
                <div class="w-[18%] border rounded border-gray-300 px-1 py-0.5">
                  <%= if matched? do %>
                    <span class="text-green-700 text-xs font-semibold">{gettext("Matched")}</span>
                    <button
                      phx-click="unmatch_group"
                      phx-value-group-id={line.match_group_id}
                      class="text-red-500 hover:text-red-700 ml-0.5"
                      title={gettext("Unmatch group")}
                      tabindex="-1"
                    >x</button>
                  <% else %>
                    <span class="text-red-400 font-semibold">{gettext("Unmatched")}</span>
                  <% end %>
                </div>
              </div>
            <% end %>
            <div :if={@statement_lines == []} class="text-center text-gray-500 p-4 text-sm">
              {gettext("No statement lines. Upload a CSV file.")}
            </div>
          </div>
        </div>

        <%!-- Right: Book Transactions --%>
        <div>
          <div class="font-semibold text-center bg-blue-200 rounded p-1 mb-1 text-sm">
            {gettext("Book Transactions")} ({length(@book_transactions)})
          </div>
          <div class="font-medium flex flex-row text-center tracking-tighter text-xs mb-1">
            <div class="w-[3%]"></div>
            <div class="w-[11%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Date")}</div>
            <div class="w-[11%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Doc#")}</div>
            <div class="w-[11%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Type")}</div>
            <div class="w-[34%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Particulars")}</div>
            <div class="w-[15%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Amount")}</div>
            <div class="w-[15%] border rounded bg-gray-200 border-gray-400 px-1 py-0.5">{gettext("Status")}</div>
          </div>
          <div class="max-h-[65vh] overflow-y-auto">
            <%= for txn <- @book_transactions do %>
              <% matched? = txn.reconciled %>
              <% suggested? = MapSet.member?(@suggested_txn, txn.id) %>
              <% selected? = MapSet.member?(@selected_txn_ids, txn.id) %>
              <div
                phx-click={unless matched?, do: "toggle_txn"}
                phx-value-id={txn.id}
                class={[
                  "flex flex-row text-center tracking-tighter text-xs",
                  not matched? && "cursor-pointer",
                  matched? && !selected? && "bg-green-100",
                  suggested? && !matched? && !selected? && "bg-yellow-100",
                  selected? && "ring-2 ring-blue-500 bg-blue-50",
                  not matched? && not suggested? && not selected? && "bg-red-50 hover:bg-red-100"
                ]}
              >
                <div class="w-[3%] py-0.5">
                  <input
                    :if={not matched?}
                    type="checkbox"
                    checked={selected?}
                    class="rounded border-gray-400"
                    phx-click="toggle_txn"
                    phx-value-id={txn.id}
                  />
                </div>
                <div class="w-[11%] border rounded border-gray-300 px-1 py-0.5">{format_date(txn.doc_date)}</div>
                <div class="w-[11%] border rounded border-gray-300 px-1 py-0.5 truncate">
                  <.doc_link doc_obj={txn} current_company={@current_company} />
                </div>
                <div class="w-[11%] border rounded border-gray-300 px-1 py-0.5 truncate">{txn.doc_type}</div>
                <div class="w-[34%] border rounded border-gray-300 px-1 py-0.5 text-left truncate" title={txn.particulars}>{txn.particulars}</div>
                <div class="w-[15%] border rounded border-gray-300 px-1 py-0.5">
                  {format_amount(txn.amount)}
                </div>
                <div class="w-[15%] border rounded border-gray-300 px-1 py-0.5">
                  <%= if matched? do %>
                    <span class="text-green-700 text-xs font-semibold">{gettext("Matched")}</span>
                    <button
                      :if={txn.match_group_id}
                      phx-click="unmatch_group"
                      phx-value-group-id={txn.match_group_id}
                      class="text-red-500 hover:text-red-700 ml-0.5"
                      title={gettext("Unmatch group")}
                      tabindex="-1"
                    >x</button>
                  <% else %>
                    <span class="text-red-400 font-semibold">{gettext("Unmatched")}</span>
                  <% end %>
                </div>
              </div>
            <% end %>
            <div :if={@book_transactions == []} class="text-center text-gray-500 p-4 text-sm">
              {gettext("No transactions found for this period.")}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
