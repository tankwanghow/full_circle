defmodule FullCircleWeb.CsvController do
  use FullCircleWeb, :controller

  def show(conn, %{
        "company_id" => com_id,
        "report" => "epfsocsoeis",
        "rep" => rep,
        "code" => code,
        "month" => month,
        "year" => year
      }) do
    {col, row} =
      cond do
        rep == "EPF" ->
          FullCircle.HR.epf_submit_file_format_query(
            month,
            year,
            code,
            com_id
          )

        rep == "SOCSO" ->
          FullCircle.HR.socso_submit_file_format_query(
            month,
            year,
            code,
            com_id
          )

        rep == "EIS" ->
          FullCircle.HR.eis_submit_file_format_query(
            month,
            year,
            code,
            com_id
          )

        rep == "SOCSO+EIS" ->
          FullCircle.HR.socso_eis_submit_file_format_query(
            month,
            year,
            code,
            com_id
          )

        true ->
          []
      end

    filename = "#{rep}_#{month}_#{year}"

    send_csv_row_col(conn, row, col, filename)
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
    fields = data |> Enum.at(0) |> Map.keys()
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
    com = get_session(conn, "current_company")
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    {col, row} = FullCircle.Reporting.fixed_assets(tdate, com)

    filename = "fixed_assets_report_#{tdate}"

    send_csv_row_col(conn, row, col, filename)
  end

  def show(conn, %{"report" => "queries", "id" => id}) do
    com = get_session(conn, "current_company")
    user = conn.assigns.current_user

    q = FullCircle.StdInterface.get!(FullCircle.UserQueries.Query, id)

    {col, row} = FullCircle.UserQueries.execute(q.sql_string, com, user)

    filename = "#{q.qry_name}_#{Timex.now() |> Timex.format!("%Y%m%d%H%M%S", :strftime)}"

    send_csv_row_col(conn, row, col, filename)
  end

  def show(conn, %{
        "report" => "post_dated_cheque_listing",
        "tdate" => tdate
      }) do
    com = get_session(conn, "current_company")
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

  def show(conn, %{
        "company_id" => com_id,
        "days" => days,
        "rep" => rep,
        "report" => "aging",
        "tdate" => tdate
      }) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data =
      cond do
        rep == "Debtors Aging" ->
          FullCircle.Reporting.debtor_aging_report(tdate, days |> String.to_integer(), com_id)

        rep == "Creditors Aging" ->
          FullCircle.Reporting.creditor_aging_report(tdate, days |> String.to_integer(), com_id)

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

  def show(conn, %{"company_id" => com_id, "report" => "harvrepo", "tdate" => tdate}) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    data = FullCircle.Layer.harvest_report(tdate, com_id)
    fields = data |> Enum.at(0) |> Map.keys()
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
    fields = data |> Enum.at(0) |> Map.keys()
    filename = "harvest_wage_report_#{fdate}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "goodsales",
        "contact" => contact,
        "goods" => goods,
        "fdate" => fdate,
        "tdate" => tdate
      }) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    fdate = fdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data =
      FullCircle.TaggedBill.goods_sales_report(
        contact,
        goods,
        fdate,
        tdate,
        com_id
      )

    fields = [
      :doc_date,
      :doc_type,
      :doc_no,
      :contact,
      :good,
      :pack_name,
      :pack_qty,
      :qty,
      :unit,
      :price,
      :amount
    ]

    filename = "good_sales_#{fdate}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
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

    fields = data |> Enum.at(0) |> Map.keys()
    filename = "weight_good_report_#{fdate}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "tbplbs",
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

        true ->
          []
      end

    fields = [:type, :name, :balance]
    filename = "#{rep |> String.replace(" ", "") |> Macro.underscore()}_#{tdate}"
    send_csv_map(conn, data, fields, filename)
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
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}.csv\"")
    |> put_root_layout(false)
    |> send_resp(
      200,
      csv_map(data, fields)
    )
  end

  defp send_csv_row_col(conn, data, fields, filename) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}.csv\"")
    |> put_root_layout(false)
    |> send_resp(
      200,
      csv_row_col(data, fields)
    )
  end

  defp csv_row_col(data, fields) do
    [fields | data] |> NimbleCSV.RFC4180.dump_to_iodata()
  end

  defp csv_map(data, fields) do
    body = data |> Enum.map(fn d -> Enum.map(fields, fn f -> Map.fetch!(d, f) end) end)

    [fields | body] |> NimbleCSV.RFC4180.dump_to_iodata()
  end
end
