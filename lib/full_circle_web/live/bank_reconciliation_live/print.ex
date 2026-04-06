defmodule FullCircleWeb.BankReconciliationLive.Print do
  use FullCircleWeb, :live_view

  alias FullCircle.BankReconciliation

  @impl true
  def mount(params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :view_bank_reconciliation,
         socket.assigns.current_company
       ) do
      mount_authorized(params, socket)
    else
      {:ok,
       socket
       |> assign(page_title: gettext("Print"))
       |> assign(error: gettext("Not authorized."))
       |> assign(account: nil, company: nil, fdate: nil, tdate: nil)}
    end
  end

  defp mount_authorized(params, socket) do
    account_name = params["name"]
    f_date = params["fdate"]
    t_date = params["tdate"]

    account =
      BankReconciliation.get_account_by_name(
        account_name,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    from = Date.from_iso8601!(f_date)
    to = Date.from_iso8601!(t_date)
    company = socket.assigns.current_company

    snapshot = BankReconciliation.load_snapshot(account.id, company.id, from, to)

    if snapshot do
      report = deserialize_report(snapshot.report_snapshot["report"])
      summary = deserialize_summary(snapshot.report_snapshot["summary"])
      stmt_closing = parse_decimal(snapshot.report_snapshot["stmt_closing"])
      book_closing = parse_decimal(snapshot.report_snapshot["book_closing"])

      {:ok,
       socket
       |> assign(page_title: gettext("Print"))
       |> assign(account: account)
       |> assign(company: company)
       |> assign(fdate: from, tdate: to)
       |> assign(report: report)
       |> assign(summary: summary)
       |> assign(stmt_closing: stmt_closing)
       |> assign(book_closing: book_closing)
       |> assign(finalized_at: snapshot.finalized_at)
       |> assign(error: nil)}
    else
      {:ok,
       socket
       |> assign(page_title: gettext("Print"))
       |> assign(error: gettext("Period not finalized. Please finalize before printing."))
       |> assign(account: account, company: company, fdate: from, tdate: to)}
    end
  end

  defp deserialize_report(report_map) do
    %{
      unmatched_stmt_deposits: deserialize_items(report_map["unmatched_stmt_deposits"] || []),
      unmatched_stmt_payments: deserialize_items(report_map["unmatched_stmt_payments"] || []),
      unmatched_book_deposits: deserialize_items(report_map["unmatched_book_deposits"] || []),
      unmatched_book_payments: deserialize_items(report_map["unmatched_book_payments"] || [])
    }
  end

  defp deserialize_items(items) do
    Enum.map(items, fn item ->
      item
      |> Map.new(fn
        {"amount", v} -> {:amount, Decimal.new(v)}
        {"statement_date", v} -> {:statement_date, Date.from_iso8601!(v)}
        {"doc_date", v} -> {:doc_date, Date.from_iso8601!(v)}
        {k, v} -> {String.to_atom(k), v}
      end)
    end)
  end

  defp deserialize_summary(summary_map) do
    %{
      statement_count: summary_map["statement_count"],
      book_count: summary_map["book_count"],
      statement_matched: summary_map["statement_matched"],
      statement_unmatched: summary_map["statement_unmatched"],
      book_reconciled: summary_map["book_reconciled"],
      book_unreconciled: summary_map["book_unreconciled"]
    }
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(str), do: Decimal.new(str)

  @impl true
  def render(%{error: error} = assigns) when not is_nil(error) do
    ~H"""
    <div id="print-me" class="print-here">
      <div style="padding: 40mm; text-align: center;">
        <p style="font-size: 1.2rem; color: #c00;">{@error}</p>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    unmatched_book_deposit_total =
      sum_amounts(assigns.report.unmatched_book_deposits)

    unmatched_book_payment_total =
      sum_amounts(assigns.report.unmatched_book_payments)

    unmatched_stmt_deposit_total =
      sum_amounts(assigns.report.unmatched_stmt_deposits)

    unmatched_stmt_payment_total =
      sum_amounts(assigns.report.unmatched_stmt_payments)

    adjusted_bank_balance =
      (assigns.stmt_closing || Decimal.new(0))
      |> Decimal.add(unmatched_book_deposit_total)
      |> Decimal.add(unmatched_book_payment_total)

    adjusted_book_balance =
      assigns.book_closing
      |> Decimal.add(unmatched_stmt_deposit_total)
      |> Decimal.add(unmatched_stmt_payment_total)

    assigns =
      assign(assigns,
        unmatched_book_deposit_total: unmatched_book_deposit_total,
        unmatched_book_payment_total: unmatched_book_payment_total,
        unmatched_stmt_deposit_total: unmatched_stmt_deposit_total,
        unmatched_stmt_payment_total: unmatched_stmt_payment_total,
        adjusted_bank_balance: adjusted_bank_balance,
        adjusted_book_balance: adjusted_book_balance
      )

    ~H"""
    <div id="print-me" class="print-here">
      {style(assigns)}
      <div class="page">
        <div class="title has-text-weight-bold is-size-5" style="text-align: center; padding-bottom: 3mm;">
          {gettext("Bank Reconciliation Statement")}
        </div>
        <div style="text-align: center; padding-bottom: 1mm;">
          {@company.name}
        </div>
        <div style="text-align: center; padding-bottom: 1mm;">
          {@account.name}
        </div>
        <div style="text-align: center; padding-bottom: 4mm;">
          {gettext("For the period")} {format_date(@fdate)} {gettext("to")} {format_date(@tdate)}
        </div>

        <div class="separator"></div>

        <%!-- Start: Balance per Bank Statement --%>
        <div class="line has-text-weight-bold">
          <span class="desc">{gettext("Balance per Bank Statement")} ({format_date(@tdate)})</span>
          <span class="total">{if @stmt_closing, do: fmt(@stmt_closing), else: "-"}</span>
        </div>

        <div class="separator"></div>

        <%!-- Section: Deposits in Books not in Bank --%>
        <%= if @report.unmatched_book_deposits != [] do %>
          <div class="line has-text-weight-semibold" style="padding-top: 2mm;">
            <span class="desc">{gettext("ADD: Deposits in Books not in Bank Statement")}</span>
          </div>
          <%= for txn <- @report.unmatched_book_deposits do %>
            <div class="detail-line">
              <span class="date">{format_date(txn.doc_date)}</span>
              <span class="ref">{txn.doc_no}</span>
              <span class="particular">{txn.particulars}</span>
              <span class="amount">{fmt(txn.amount)}</span>
            </div>
          <% end %>
          <div class="subtotal-line">
            <span class="desc"></span>
            <span class="total">{fmt(@unmatched_book_deposit_total)}</span>
          </div>
        <% end %>

        <%!-- Section: Payments in Books not in Bank --%>
        <%= if @report.unmatched_book_payments != [] do %>
          <div class="line has-text-weight-semibold" style="padding-top: 2mm;">
            <span class="desc">{gettext("LESS: Payments in Books not in Bank Statement")}</span>
          </div>
          <%= for txn <- @report.unmatched_book_payments do %>
            <div class="detail-line">
              <span class="date">{format_date(txn.doc_date)}</span>
              <span class="ref">{txn.doc_no}</span>
              <span class="particular">{txn.particulars}</span>
              <span class="amount">({fmt(Decimal.abs(txn.amount))})</span>
            </div>
          <% end %>
          <div class="subtotal-line">
            <span class="desc"></span>
            <span class="total">({fmt(Decimal.abs(@unmatched_book_payment_total))})</span>
          </div>
        <% end %>

        <div class="separator" style="margin-top: 3mm;"></div>

        <%!-- Adjusted Bank Balance --%>
        <div class="line has-text-weight-bold">
          <span class="desc">{gettext("Adjusted Bank Balance")}</span>
          <span class="total">{fmt(@adjusted_bank_balance)}</span>
        </div>

        <div class="separator"></div>
        <div style="padding-top: 5mm;"></div>
        <div class="separator"></div>

        <%!-- Balance per Books --%>
        <div class="line has-text-weight-bold">
          <span class="desc">{gettext("Balance per Books")} ({format_date(@tdate)})</span>
          <span class="total">{fmt(@book_closing)}</span>
        </div>

        <div class="separator"></div>

        <%!-- Section: Credits in Bank not in Books --%>
        <%= if @report.unmatched_stmt_deposits != [] do %>
          <div class="line has-text-weight-semibold" style="padding-top: 2mm;">
            <span class="desc">{gettext("ADD: Credits in Bank Statement not in Books")}</span>
          </div>
          <%= for sl <- @report.unmatched_stmt_deposits do %>
            <div class="detail-line">
              <span class="date">{format_date(sl.statement_date)}</span>
              <span class="ref">{sl.cheque_no}</span>
              <span class="particular">{sl.description}</span>
              <span class="amount">{fmt(sl.amount)}</span>
            </div>
          <% end %>
          <div class="subtotal-line">
            <span class="desc"></span>
            <span class="total">{fmt(@unmatched_stmt_deposit_total)}</span>
          </div>
        <% end %>

        <%!-- Section: Debits in Bank not in Books --%>
        <%= if @report.unmatched_stmt_payments != [] do %>
          <div class="line has-text-weight-semibold" style="padding-top: 2mm;">
            <span class="desc">{gettext("LESS: Debits in Bank Statement not in Books")}</span>
          </div>
          <%= for sl <- @report.unmatched_stmt_payments do %>
            <div class="detail-line">
              <span class="date">{format_date(sl.statement_date)}</span>
              <span class="ref">{sl.cheque_no}</span>
              <span class="particular">{sl.description}</span>
              <span class="amount">({fmt(Decimal.abs(sl.amount))})</span>
            </div>
          <% end %>
          <div class="subtotal-line">
            <span class="desc"></span>
            <span class="total">({fmt(Decimal.abs(@unmatched_stmt_payment_total))})</span>
          </div>
        <% end %>

        <div class="separator" style="margin-top: 3mm;"></div>

        <%!-- Adjusted Book Balance --%>
        <div class="line has-text-weight-bold">
          <span class="desc">{gettext("Adjusted Book Balance")}</span>
          <span class="total">{fmt(@adjusted_book_balance)}</span>
        </div>

        <div class="separator"></div>

        <%!-- Summary --%>
        <div style="padding-top: 5mm;">
          <div class="line is-size-7">
            <span class="desc">{gettext("Total Transactions")}:</span>
            <span class="total">
              {gettext("Stmt")}: {@summary.statement_count} | {gettext("Book")}: {@summary.book_count}
            </span>
          </div>
          <div class="line is-size-7">
            <span class="desc">{gettext("Matched")}:</span>
            <span class="total">
              {@summary.statement_matched} | {gettext("Unmatched")}: {gettext("Stmt")}: {@summary.statement_unmatched} | {gettext("Book")}: {@summary.book_unreconciled}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp fmt(amount) do
    Number.Delimit.number_to_delimited(amount)
  end

  defp format_date(date) do
    FullCircleWeb.Helpers.format_date(date)
  end

  defp sum_amounts(items) do
    Enum.reduce(items, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; min-height: 290mm; padding: 10mm 15mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 10mm 15mm; page-break-after: always; }
      }

      .separator { border-bottom: 1px solid black; margin: 1mm 0; }

      .line { display: flex; justify-content: space-between; padding: 0.5mm 0; }
      .line .desc { flex: 1; }
      .line .total { width: 40mm; text-align: right; }

      .detail-line { display: flex; padding: 0.3mm 0; font-size: 0.8rem; padding-left: 5mm; }
      .detail-line .date { width: 22mm; }
      .detail-line .ref { width: 30mm; overflow: hidden; }
      .detail-line .particular { flex: 1; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
      .detail-line .amount { width: 30mm; text-align: right; }

      .subtotal-line { display: flex; justify-content: space-between; padding: 0.5mm 0; border-top: 1px dashed #999; margin-left: 5mm; }
      .subtotal-line .total { width: 30mm; text-align: right; font-weight: 600; }
    </style>
    """
  end
end
