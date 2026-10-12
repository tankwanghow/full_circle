defmodule FullCircle.BankPayment.Rows do
  @moduledoc """
  Payment → batch line snapshot → FileSpec row. The row's own date is
  `doc_date`; `payment_date` is the batch's header value (FileSpec merges the
  header over each row).
  """

  alias FullCircle.BillPay.Payment

  @doc "Snapshot attrs. Preload :contact, payment_details: :good, transaction_matchers: :transaction."
  def line_attrs(%Payment{contact: c} = p) do
    %{
      payment_no: p.payment_no,
      doc_date: p.payment_date,
      amount: p.funds_amount,
      bank_code: c.bank_code,
      bank_account_no: c.bank_account_no,
      bank_account_name: c.bank_account_name,
      contact_name: c.name,
      email: c.email,
      reg_no: c.reg_no,
      descriptions: p.descriptions,
      advice: advice(p)
    }
  end

  defp advice(p) do
    matched =
      for m <- p.transaction_matchers, m.transaction do
        %{
          "doc_no" => m.transaction.doc_no || "",
          "doc_date" => Date.to_iso8601(m.transaction.doc_date),
          "amount" =>
            m.match_amount |> Decimal.abs() |> Decimal.round(2) |> Decimal.to_string(:normal)
        }
      end

    lines =
      for d <- p.payment_details do
        %{
          "doc_no" => d.descriptions || (d.good && d.good.name) || "",
          "doc_date" => Date.to_iso8601(p.payment_date),
          "amount" => d |> detail_amount() |> Decimal.to_string(:normal)
        }
      end

    matched ++ lines
  end

  defp detail_amount(d) do
    base = d.quantity |> Decimal.mult(d.unit_price) |> Decimal.add(d.discount)
    tax = base |> Decimal.mult(d.tax_rate) |> Decimal.round(2)
    base |> Decimal.add(tax) |> Decimal.round(2)
  end

  @doc "FileSpec row from a batch line (struct or map with :record_no)."
  def to_row(line) do
    advice = Enum.map(line.advice || [], &load_advice/1)
    {email, emails} = emails(line.email)

    %{
      "record_id" => line.record_no |> Integer.to_string() |> String.pad_leading(12, "0"),
      "payment_no" => line.payment_no,
      "doc_date" => line.doc_date,
      "amount" => line.amount,
      "bank_code" => line.bank_code,
      "account_no" => line.bank_account_no,
      "account_name" => line.bank_account_name,
      "contact_name" => line.contact_name,
      "reg_no" => line.reg_no || "",
      "email" => email,
      "emails" => emails,
      "descriptions" => line.descriptions || "",
      "advice" => advice,
      "advice_text" => advice_text(advice)
    }
  end

  @doc "{first address (blank if over 70 chars), all addresses joined with ;}"
  def emails(nil), do: {"", ""}

  def emails(text) do
    all =
      text |> String.split(~r/[\s,;\/]+/, trim: true) |> Enum.filter(&String.contains?(&1, "@"))

    first =
      case all do
        [a | _] when byte_size(a) <= 70 -> a
        _ -> ""
      end

    {first, Enum.join(all, ";")}
  end

  defp load_advice(a) do
    %{
      "doc_no" => a["doc_no"] || "",
      "doc_date" => Date.from_iso8601!(a["doc_date"]),
      "amount" => Decimal.new(a["amount"])
    }
  end

  @doc "`<doc_no> <DD/MM/YYYY> <amount>; …` — for banks with free-text advice lines."
  def advice_text(advice) do
    Enum.map_join(advice, "; ", fn a ->
      "#{a["doc_no"]} #{Calendar.strftime(a["doc_date"], "%d/%m/%Y")} " <>
        (a["amount"] |> Decimal.round(2) |> Decimal.to_string(:normal))
    end)
  end
end
