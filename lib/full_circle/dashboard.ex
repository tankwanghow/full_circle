defmodule FullCircle.Dashboard do
  @moduledoc """
  Lightweight “Today” snapshot for the company dashboard.
  """

  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.Transaction

  @doc """
  Counts of finance documents dated today (company timezone when set).
  """
  def today_snapshot(company, user) do
    today = today_for(company)

    types =
      for {type, action} <- [
            {"Invoice", :update_invoice},
            {"PurInvoice", :update_pur_invoice},
            {"Receipt", :update_receipt},
            {"Payment", :update_payment},
            {"Deposit", :update_deposit},
            {"Journal", :update_journal}
          ],
          can?(user, action, company),
          do: type

    counts =
      if types == [] do
        %{}
      else
        from(t in Transaction,
          join: com in subquery(Sys.user_company(company, user)),
          on: com.id == t.company_id,
          where: t.doc_date == ^today,
          where: t.doc_type in ^types,
          where: not is_nil(t.doc_id),
          group_by: t.doc_type,
          select: {t.doc_type, count(fragment("DISTINCT ?", t.doc_id))}
        )
        |> Repo.all()
        |> Map.new()
      end

    %{
      date: today,
      counts: counts,
      total: counts |> Map.values() |> Enum.sum()
    }
  end

  defp today_for(%{timezone: tz}) when is_binary(tz) and tz != "" do
    case DateTime.now(tz) do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

  defp today_for(_), do: Date.utc_today()

  def type_label("Invoice"), do: "Invoices"
  def type_label("PurInvoice"), do: "Purchase Invoices"
  def type_label("Receipt"), do: "Receipts"
  def type_label("Payment"), do: "Payments"
  def type_label("Deposit"), do: "Deposits"
  def type_label("Journal"), do: "Journals"
  def type_label(other), do: other
end
