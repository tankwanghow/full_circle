defmodule FullCircleWeb.CsvController do
  use FullCircleWeb, :controller

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

    send_csv(conn, data, [:doc_date, :doc_type, :doc_no, :particulars, :amount], filename)
  end

  defp send_csv(conn, data, fields, filename) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}.csv\"")
    |> put_root_layout(false)
    |> send_resp(
      200,
      to_csv(data, fields)
    )
  end

  defp to_csv(data, fields) do
    body = data |> Enum.map(fn d -> Enum.map(fields, fn f -> Map.fetch!(d, f) end) end)

    [fields | body] |> NimbleCSV.RFC4180.dump_to_iodata()
  end
end
