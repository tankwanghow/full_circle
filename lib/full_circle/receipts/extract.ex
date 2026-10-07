defmodule FullCircle.Receipts.Extract do
  @moduledoc """
  A photographed bill or receipt (JPEG/PNG/WebP/PDF) → `%Extracted{}`, via the
  company's receipt AI (`Sys.llm_settings(company, :receipt)`). Knows nothing
  about forms, so a future captured-receipts inbox can call it as is. The
  model's answer is never trusted: every value is parsed here, and what does
  not parse becomes nil with a warning. Contract: `.claude/skills/receipt-capture.md`.
  """
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.BankReconciliation.LlmClient
  alias FullCircle.Receipts.Extracted

  @max_image_bytes 5 * 1024 * 1024
  @summary_max 200
  @image_types ~w(image/jpeg image/png image/webp)

  @system_prompt """
  You read photos and PDFs of Malaysian supplier bills, invoices, cash bills and
  shop receipts. Reply with ONE JSON object and nothing else:

  {"recognized": true|false,
   "summary": "one plain sentence of what the picture shows",
   "supplier": {"name": str|null, "tin": str|null, "brn": str|null, "sst_no": str|null},
   "doc_no": str|null, "date": "YYYY-MM-DD"|null, "due_date": "YYYY-MM-DD"|null,
   "lines": [{"description": str, "quantity": num|null, "unit_price": num|null,
              "discount": num|null, "tax_rate_percent": num|null, "amount": num|null}],
   "subtotal": num|null, "tax_total": num|null, "rounding": num|null, "total": num|null,
   "payment_method": "cash"|"card"|"transfer"|"cheque"|null,
   "e_invoice_uuid": str|null}

  Rules:
  - Use null for anything not printed or not legible. Never guess.
  - recognized is false when the picture is not a bill, invoice, cash bill or
    receipt (a delivery order, cheque, letter, product photo, unreadable shot).
    Then leave every other field null and lines empty.
  - summary is always set, max 200 characters, e.g. "Petrol receipt from
    Petronas Bukit Mertajam, RM 80.00" or "Blurry photo of a handwritten note".
  - Dates as YYYY-MM-DD. Printed numeric dates are Malaysian DD/MM/YYYY.
  - Amounts are plain numbers: no currency, no thousands separators.
  - One line per item row, handwritten cash-bill rows included. amount is the
    line total as printed.
  - tax_rate_percent is the line's tax percentage (6 for 6%), null if not shown
    per line. tax_total is the total SST/service tax printed.
  - rounding is the rounding adjustment (e.g. -0.02), never a line.
  - total is the final amount payable.
  - supplier is the business that issued the document, not the buyer.
    tin = Tax Identification No (e.g. C20880050010), brn = business
    registration no (e.g. 201901012345 or 123456-K), sst_no = SST registration.
  - e_invoice_uuid is the LHDN e-invoice UUID / validation id if printed.
  """

  @user_prompt "Read this document."
  @json_only "Reply with the JSON object only."

  def run(path, content_type, settings, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    llm_opts = [timeout: Keyword.get(opts, :timeout, 90_000), max_tokens: 4096]

    with {:ok, kind} <- kind(content_type),
         {:ok, bin} <- read(path, kind) do
      data = Base.encode64(bin)
      ask = fn prompt -> ask(kind, settings, prompt, data, content_type, llm_opts) end

      with {:ok, text, usage} <- ask.(@user_prompt) do
        case decode_json(text) do
          {:ok, map} -> {:ok, parse(map, today), usage}
          :error -> retry(ask, today)
        end
      end
    end
  end

  defp retry(ask, today) do
    with {:ok, text, usage} <- ask.(@user_prompt <> " " <> @json_only) do
      case decode_json(text) do
        {:ok, map} -> {:ok, parse(map, today), usage}
        :error -> {:error, gettext("The AI's answer could not be read. Try ↻ Read again.")}
      end
    end
  end

  defp kind("application/pdf"), do: {:ok, :pdf}
  defp kind(ct) when ct in @image_types, do: {:ok, :image}
  defp kind(_), do: {:error, gettext("Only photos and PDFs can be read.")}

  defp read(path, kind) do
    case File.read(path) do
      {:ok, bin} when kind == :image and byte_size(bin) > @max_image_bytes ->
        {:error, gettext("Photo too large to read (max 5 MB).")}

      {:ok, bin} ->
        {:ok, bin}

      {:error, _} ->
        {:error, gettext("Receipt file is missing.")}
    end
  end

  defp ask(:pdf, settings, prompt, data, _ct, opts),
    do: LlmClient.call_with_pdf(settings, @system_prompt, prompt, data, opts)

  defp ask(:image, settings, prompt, data, ct, opts),
    do: LlmClient.call_with_image(settings, @system_prompt, prompt, data, ct, opts)

  @doc "The first `{…}` object in a model reply (fences and chatter tolerated)."
  def decode_json(text) when is_binary(text) do
    with [json] <- Regex.run(~r/\{.*\}/s, text),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  def decode_json(_), do: :error

  @doc "A decoded model reply → `%Extracted{}`, with warnings for what does not hold."
  def parse(map, today) when is_map(map) do
    summary = map |> Map.get("summary") |> text() |> cut(@summary_max)
    supplier = if is_map(map["supplier"]), do: map["supplier"], else: %{}

    {fields, warnings} =
      [
        {:date, map, "date", &date/1},
        {:due_date, map, "due_date", &date/1},
        {:subtotal, map, "subtotal", &dec/1},
        {:tax_total, map, "tax_total", &dec/1},
        {:rounding, map, "rounding", &dec/1},
        {:total, map, "total", &dec/1}
      ]
      |> Enum.map_reduce([], fn {key, src, name, parser}, acc ->
        {value, warning} = field(src, name, parser)
        {{key, value}, if(warning, do: [warning | acc], else: acc)}
      end)

    f = Map.new(fields)
    lines = map |> Map.get("lines") |> List.wrap() |> Enum.flat_map(&line/1)

    if map["recognized"] == false or (is_nil(f.total) and lines == []) do
      %Extracted{
        recognized: false,
        summary: summary,
        warnings: [gettext("Not recognised as a bill or receipt.")]
      }
    else
      supplier_name = text(supplier["name"])
      lines = if lines == [] and f.total, do: [total_line(supplier_name, f)], else: lines

      %Extracted{
        recognized: true,
        summary: summary,
        supplier_name: supplier_name,
        supplier_tin: text(supplier["tin"]),
        supplier_brn: text(supplier["brn"]),
        supplier_sst_no: text(supplier["sst_no"]),
        doc_no: text(map["doc_no"]),
        date: f.date,
        due_date: f.due_date,
        lines: lines,
        subtotal: f.subtotal,
        tax_total: f.tax_total,
        rounding: f.rounding,
        total: f.total,
        payment_method: payment_method(map["payment_method"]),
        e_invoice_uuid: text(map["e_invoice_uuid"]),
        warnings:
          Enum.reverse(warnings) ++
            Enum.reject(
              [sum_warning(lines, f), date_warning(f.date, today), negative_warning(f.total)],
              &is_nil/1
            )
      }
    end
  end

  defp field(src, name, parser) do
    raw = Map.get(src, name)

    case {raw, parser.(raw)} do
      {nil, _} ->
        {nil, nil}

      {"", _} ->
        {nil, nil}

      {_, nil} ->
        {nil, gettext("Could not read %{field}: %{value}", field: name, value: inspect(raw))}

      {_, value} ->
        {value, nil}
    end
  end

  defp line(%{} = l) do
    descr = text(l["description"])
    qty = dec(l["quantity"]) || Decimal.new(1)
    discount = dec(l["discount"]) || Decimal.new(0)
    amount = dec(l["amount"])

    price =
      dec(l["unit_price"]) ||
        if(amount && not Decimal.eq?(qty, 0), do: Decimal.div(Decimal.add(amount, discount), qty))

    amount = amount || (price && Decimal.sub(Decimal.mult(qty, price), discount))

    if is_nil(descr) and is_nil(amount) do
      []
    else
      [
        %{
          descriptions: descr || "",
          quantity: qty,
          unit_price: price || Decimal.new(0),
          discount: discount,
          tax_rate: dec(l["tax_rate_percent"]),
          amount: amount || Decimal.new(0)
        }
      ]
    end
  end

  defp line(_), do: []

  defp total_line(supplier_name, f) do
    net = f.total |> Decimal.sub(f.tax_total || 0) |> Decimal.sub(f.rounding || 0)

    %{
      descriptions: supplier_name || gettext("Receipt"),
      quantity: Decimal.new(1),
      unit_price: net,
      discount: Decimal.new(0),
      tax_rate: nil,
      amount: net
    }
  end

  # Lines may be printed before tax (SST added below) or tax-inclusive; either
  # adding up to the total is fine.
  defp sum_warning(_lines, %{total: nil}), do: nil

  defp sum_warning(lines, f) do
    sum = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.amount, &2))
    rounding = f.rounding || Decimal.new(0)
    without_tax = Decimal.add(sum, rounding)
    with_tax = Decimal.add(without_tax, f.tax_total || 0)

    if close?(with_tax, f.total) or close?(without_tax, f.total) do
      nil
    else
      gettext(
        "Receipt lines don't add up: lines %{lines} + tax %{tax} + rounding %{r} ≠ total %{total}.",
        lines: sum,
        tax: f.tax_total || 0,
        r: rounding,
        total: f.total
      )
    end
  end

  defp close?(a, b), do: Decimal.lt?(Decimal.abs(Decimal.sub(a, b)), Decimal.new("0.01"))

  defp date_warning(nil, _today), do: nil

  defp date_warning(date, today) do
    cond do
      Date.compare(date, today) == :gt ->
        gettext("Receipt date %{d} is in the future.", d: date)

      Date.diff(today, date) > 365 ->
        gettext("Receipt date %{d} is more than a year old.", d: date)

      true ->
        nil
    end
  end

  defp negative_warning(nil), do: nil

  defp negative_warning(total) do
    if Decimal.negative?(total),
      do: gettext("Total is negative — this looks like a refund or credit note."),
      else: nil
  end

  # --- value parsers: nil when not readable ---

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)

  defp dec(s) when is_binary(s) do
    case s |> String.replace(~r/[^0-9.\-]/, "") |> Decimal.parse() do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp dec(_), do: nil

  defp date(s) when is_binary(s) do
    s = String.trim(s)

    case Date.from_iso8601(s) do
      {:ok, d} ->
        d

      _ ->
        with [_, dd, mm, yyyy] <- Regex.run(~r/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{4})$/, s),
             {:ok, d} <-
               Date.new(String.to_integer(yyyy), String.to_integer(mm), String.to_integer(dd)) do
          d
        else
          _ -> nil
        end
    end
  end

  defp date(_), do: nil

  defp payment_method(m) when m in ~w(cash card transfer cheque), do: m
  defp payment_method(_), do: nil

  defp text(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp text(_), do: nil

  defp cut(nil, _max), do: nil
  defp cut(s, max), do: String.slice(s, 0, max)
end
