defmodule FullCircleWeb.CsvController do
  use FullCircleWeb, :controller

  alias FullCircle.{HR, Repo, StatutoryConfig}
  alias FullCircle.UserQueries.Query

  def show(conn, %{
        "company_id" => com_id,
        "report" => "epfsocsoeis",
        "rep" => rep,
        "code" => code,
        "month" => month,
        "year" => year
      }) do
    month = String.to_integer(month)
    year = String.to_integer(year)

    case render_epfsocsoeis(com_id, rep, month, year, code) do
      {:ok, {filename, text}} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> put_root_layout(false)
        |> send_resp(200, text)

      {:legacy, payload} ->
        send_epfsocsoeis_legacy(conn, rep, payload, month, year)
    end
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "tagged_bills",
        "tags" => tags,
        "fdate" => fdate,
        "tdate" => tdate
      }) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    fdate = fdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    data = FullCircle.TaggedBill.transport_commission(tags, fdate, tdate, com_id)
    fields = fields_from(data)
    filename = "driver_commission_#{fdate}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "actrans",
        "fdate" => fdate,
        "tdate" => tdate,
        "name" => name
      }) do
    transactions_csv(
      conn,
      name,
      fdate,
      tdate,
      com_id,
      &FullCircle.Accounting.get_account_by_name/3,
      &FullCircle.Reporting.account_transactions/4
    )
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "contacttrans",
        "fdate" => fdate,
        "tdate" => tdate,
        "name" => name
      }) do
    transactions_csv(
      conn,
      name,
      fdate,
      tdate,
      com_id,
      &FullCircle.Accounting.get_contact_by_name/3,
      &FullCircle.Reporting.contact_transactions/4
    )
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "housefeed",
        "month" => mth,
        "year" => yr,
        "field" => fld,
        "feed_str" => feed_str
      }) do
    {col, row} =
      FullCircle.Layer.house_feed_type_query(mth, yr, com_id, feed_str, fld)
      |> FullCircle.Helpers.exec_query_row_col()

    filename = "house_#{fld}_#{mth}_#{yr}"
    send_csv_row_col(conn, row, col, filename)
  end

  def show(conn, %{
        "report" => "fixed_assets_report",
        "tdate" => tdate
      }) do
    com = FullCircleWeb.ActiveCompany.active_company(conn)
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    {col, row} = FullCircle.Reporting.fixed_assets(tdate, com)

    filename = "fixed_assets_report_#{tdate}"

    send_csv_row_col(conn, row, col, filename)
  end

  def show(conn, %{"company_id" => com_id, "report" => "queries", "id" => id}) do
    com = FullCircleWeb.ActiveCompany.active_company(conn)
    user = conn.assigns.current_user

    case saved_query(com_id, id) do
      nil ->
        send_resp(conn, 404, "not found")

      q ->
        # execute/3 also returns {:error, :not_authorise}, which matches
        # {col, row} and used to reach the encoder as a pair of column names.
        case FullCircle.UserQueries.execute(q.sql_string, com, user) do
          {:error, :not_authorise} ->
            send_resp(conn, 403, "forbidden")

          {col, row} ->
            stamp = Timex.now() |> Timex.format!("%Y%m%d%H%M%S", :strftime)
            send_csv_row_col(conn, row, col, "#{q.qry_name}_#{stamp}")
        end
    end
  end

  def show(conn, %{
        "report" => "post_dated_cheque_listing",
        "tdate" => tdate
      }) do
    com = FullCircleWeb.ActiveCompany.active_company(conn)
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data = FullCircle.Reporting.contact_undeposit_cheques(tdate, com)

    fields = [
      :receipt_date,
      :receipt_no,
      :contact_name,
      :bank,
      :chq_no,
      :amount,
      :deposit_date,
      :deposit_no,
      :return_no,
      :return_date
    ]

    filename = "post_dated_cheque_listing#{tdate}"

    send_csv_map(conn, data, fields, filename)
  end

  def show(
        conn,
        %{
          "company_id" => com_id,
          "rep" => rep,
          "report" => "aging",
          "tdate" => tdate
        } = params
      ) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    cutoffs = FullCircle.Reporting.AgingBuckets.parse_cutoffs(params)

    data =
      cond do
        rep == "Debtors Aging" ->
          FullCircle.Reporting.debtor_aging_report(tdate, cutoffs, com_id)

        rep == "Creditors Aging" ->
          FullCircle.Reporting.creditor_aging_report(tdate, cutoffs, com_id)

        true ->
          []
      end

    filename = "#{rep |> String.replace(" ", "") |> Macro.underscore()}_#{tdate}"

    send_csv_map(
      conn,
      data,
      [:contact_name, :p1, :p2, :p3, :p4, :p5, :total, :pd_amt, :pd_chqs],
      filename
    )
  end

  def show(conn, %{"company_id" => com_id, "report" => "harvrepo", "tdate" => tdate} = params) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data =
      FullCircle.Layer.harvest_report(tdate, com_id)
      |> FullCircle.Layer.sort_harvest_report(params["sort_by"], params["sort_dir"])

    fields = fields_from(data)
    filename = "harvest_report_#{tdate}"
    send_csv_map(conn, data, fields, filename)
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "harvwagrepo",
        "fdate" => fdate,
        "tdate" => tdate
      }) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    fdate = fdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    data = FullCircle.Layer.harvest_wage_report(fdate, tdate, com_id)
    fields = fields_from(data)
    filename = "harvest_wage_report_#{fdate}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
  end

  def show(
        conn,
        %{
          "company_id" => com_id,
          "report" => "goodsales",
          "contact" => contact,
          "goods" => goods,
          "fdate" => fdate,
          "tdate" => tdate
        } = params
      ) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    fdate = fdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data =
      FullCircle.TaggedBill.goods_sales_report(
        contact,
        goods,
        fdate,
        tdate,
        com_id,
        good_snp_opts(params)
      )

    filename = "good_sales_#{fdate}_#{tdate}"
    send_csv_map(conn, data, good_snp_fields(), filename)
  end

  def show(
        conn,
        %{
          "company_id" => com_id,
          "report" => "goodpurchases",
          "contact" => contact,
          "goods" => goods,
          "fdate" => fdate,
          "tdate" => tdate
        } = params
      ) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    fdate = fdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data =
      FullCircle.TaggedBill.goods_purchases_report(
        contact,
        goods,
        fdate,
        tdate,
        com_id,
        good_snp_opts(params)
      )

    filename = "good_purchases_#{fdate}_#{tdate}"
    send_csv_map(conn, data, good_snp_fields(), filename)
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "weigoodrepo",
        "glist" => glist,
        "fdate" => fdate,
        "tdate" => tdate
      }) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    fdate = fdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data =
      FullCircle.WeightBridge.goods_report(
        glist,
        fdate,
        tdate,
        com_id
      )

    fields = fields_from(data)
    filename = "weight_good_report_#{fdate}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "financial_statements",
        "rep" => rep,
        "tdate" => tdate
      }) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    com = FullCircle.Sys.get_company!(com_id)

    data =
      cond do
        rep == "Trail Balance" ->
          FullCircle.Reporting.trail_balance(tdate, com)

        rep == "Profit Loss" ->
          FullCircle.Reporting.profit_loss(tdate, com)

        rep == "Balance Sheet" ->
          FullCircle.Reporting.balance_sheet(tdate, com)

        rep == "Cash Flow" ->
          fdate =
            conn.params["fdate"] |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

          FullCircle.Reporting.cash_flow(fdate, tdate, com) ++
            [
              %{
                type: "Cash",
                name: "Cash at Beginning of Period",
                balance: FullCircle.Reporting.cash_balance(Date.add(fdate, -1), com)
              },
              %{
                type: "Cash",
                name: "Cash at End of Period",
                balance: FullCircle.Reporting.cash_balance(tdate, com)
              }
            ]

        true ->
          []
      end

    fields = [:type, :name, :balance]
    filename = "#{rep |> String.replace(" ", "") |> Macro.underscore()}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
  end

  defp render_epfsocsoeis(com_id, rep, month, year, employer_code) do
    case StatutoryConfig.report_format_code(rep) do
      nil ->
        {:legacy, legacy_payload(rep, month, year, employer_code, com_id)}

      format_code ->
        case StatutoryConfig.render_file(com_id, format_code, month, year, employer_code) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:legacy, legacy_payload(rep, month, year, employer_code, com_id)}
        end
    end
  end

  defp legacy_payload("PCB", month, year, code, com_id) do
    {:pcb, HR.Statutory.pcb_text(month, year, code, com_id)}
  end

  defp legacy_payload("Contributions", month, year, _code, com_id) do
    {:rows, HR.contributions_report(month, year, com_id)}
  end

  defp legacy_payload(rep, month, year, code, com_id) do
    {:rows, HR.Statutory.rows(rep, month, year, code, com_id)}
  end

  defp send_epfsocsoeis_legacy(conn, "PCB", {:pcb, text}, _month, _year) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"#{HR.Statutory.PcbFormat.filename()}\""
    )
    |> put_root_layout(false)
    |> send_resp(200, text)
  end

  defp send_epfsocsoeis_legacy(conn, rep, {:rows, {col, row}}, month, year) do
    send_csv_row_col(conn, row, col, "#{rep}_#{month}_#{year}")
  end

  defp transactions_csv(conn, name, fdate, tdate, com_id, name_func, trans_func) do
    com = FullCircle.Sys.get_company!(com_id)

    ac = name_func.(name, com, conn.assigns.current_user)

    data =
      trans_func.(
        ac,
        Date.from_iso8601!(fdate),
        Date.from_iso8601!(tdate),
        com
      )

    filename =
      [
        String.replace(name, " ", "") |> String.slice(0..10),
        String.replace(fdate, "-", ""),
        String.replace(tdate, "-", "")
      ]
      |> Enum.join("_")

    send_csv_map(conn, data, [:doc_date, :doc_type, :doc_no, :particulars, :amount], filename)
  end

  defp send_csv_map(conn, data, fields, filename) do
    rows = Stream.map(data, fn d -> Enum.map(fields, fn f -> Map.fetch!(d, f) end) end)
    send_csv(conn, fields, rows, filename)
  end

  defp send_csv_row_col(conn, data, fields, filename) do
    send_csv(conn, fields, data, filename)
  end

  # StdInterface.get!/2 is an unscoped Repo.get!, so an id belonging to another
  # company would be loaded and its SQL run. Scope it, and treat a malformed id
  # as absent rather than letting it raise Ecto.Query.CastError as a 500.
  defp saved_query(com_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Query, id: uuid, company_id: com_id)
      :error -> nil
    end
  end

  # A report that matched nothing has no first row to read column names from.
  # That is a normal outcome, so the export is simply empty.
  defp fields_from([first | _]), do: Map.keys(first)
  defp fields_from([]), do: []

  # Chunked rather than one send_resp/3: encoding the whole export into a single
  # binary first meant the rows AND their encoded copy were resident at once, on
  # a box where an OOM takes the container down for good (no restart policy).
  # The rows themselves still come from a fully-materialised query, so this
  # halves peak memory rather than making it constant — bounding the query is a
  # separate job.
  defp send_csv(conn, fields, rows, filename) do
    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}.csv\"")
      |> put_root_layout(false)
      |> send_chunked(200)

    header = if fields == [], do: [], else: [fields]

    header
    |> Stream.concat(rows)
    |> Enum.reduce_while(conn, fn row, conn ->
      case chunk(conn, NimbleCSV.RFC4180.dump_to_iodata([row])) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp good_snp_opts(%{"category" => "custom"} = params) do
    [
      match: :ilike,
      name_ilike: params["name_ilike"] || "",
      desc_ilike: params["desc_ilike"] || ""
    ]
  end

  defp good_snp_opts(_), do: []

  defp good_snp_fields do
    [
      :doc_date,
      :doc_type,
      :doc_no,
      :contact,
      :good,
      :descriptions,
      :pack_name,
      :pack_qty,
      :qty,
      :unit,
      :price,
      :amount
    ]
  end
end
