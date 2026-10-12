defmodule FullCircleWeb.BankBatchController do
  use FullCircleWeb, :controller

  alias FullCircle.BankPayment

  def download(conn, %{"company_id" => com_id, "ids" => ids} = params) do
    company = FullCircle.Sys.get_company!(com_id)
    ids = String.split(ids, ",", trim: true)

    case BankPayment.download_files(ids, params["reason"], company, conn.assigns.current_user) do
      {:ok, [{name, text}]} ->
        send_download(conn, {:binary, text}, filename: name, content_type: MIME.from_path(name))

      {:ok, files} ->
        {:ok, zip} = BankPayment.zip(files)

        send_download(conn, {:binary, zip},
          filename: "bank_batches.zip",
          content_type: "application/zip"
        )

      :not_authorise ->
        conn |> put_status(403) |> text("not authorised")

      {:error, msg} ->
        conn |> put_status(422) |> text(msg)
    end
  end
end
