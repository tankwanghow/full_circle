defmodule FullCircleWeb.PhoneUploadController do
  @moduledoc """
  The one phone page (`/up/:token`) and its JSON endpoints. Plain HTTP, not
  LiveView: the camera backgrounds the page and would kill a socket. Every
  answer carries a fresh token (the 10-minute window slides with use).
  """
  use FullCircleWeb, :controller

  alias FullCircle.Notes.{Attachments, Note, Scans}
  alias FullCircleWeb.{NoteAttachmentController, PhoneUpload}

  def show(conn, %{"token" => token}) do
    case PhoneUpload.resolve(token) do
      {:ok, ctx} ->
        conn
        |> put_layout(false)
        |> put_view(FullCircleWeb.PhoneUploadHTML)
        |> render(:show,
          token: ctx.token,
          label: ctx.label,
          target_key: target_key(ctx.target),
          max_bytes: Attachments.max_bytes()
        )

      _ ->
        conn
        |> put_status(410)
        |> put_layout(false)
        |> put_view(FullCircleWeb.PhoneUploadHTML)
        |> render(:expired)
    end
  end

  # Where ✓ Close lands when the browser will not let the tab close itself.
  def done_page(conn, _params) do
    conn
    |> put_layout(false)
    |> put_view(FullCircleWeb.PhoneUploadHTML)
    |> render(:done)
  end

  def state(conn, %{"token" => token} = params) do
    with_ctx(conn, token, fn ctx ->
      pages = Scans.count(ctx.company.id, params["scan_id"] || "")
      json(conn, %{label: ctx.label, pages: pages, token: ctx.token})
    end)
  end

  def file(conn, %{"token" => token, "file" => %Plug.Upload{} = file}) do
    with_ctx(conn, token, fn ctx ->
      upload = %{path: file.path, file_name: file.filename}
      reply(conn, ctx, store(ctx, upload), &%{id: &1.id})
    end)
  end

  def file(conn, _), do: error(conn, 422, "invalid", gettext("No file received."))

  def page(conn, %{"token" => token, "scan_id" => sid, "file" => %Plug.Upload{} = file}) do
    with_ctx(conn, token, fn ctx ->
      reply(conn, ctx, Scans.add_page(ctx.company.id, sid, file.path), &%{pages: &1})
    end)
  end

  def page(conn, _), do: error(conn, 422, "invalid", gettext("No file received."))

  def drop_page(conn, %{"token" => token, "scan_id" => sid}) do
    with_ctx(conn, token, fn ctx ->
      reply(conn, ctx, Scans.drop_last(ctx.company.id, sid), &%{pages: &1})
    end)
  end

  def done(conn, %{"token" => token, "scan_id" => sid} = params) do
    with_ctx(conn, token, fn ctx ->
      name = pdf_name(params["name"])

      result =
        with {:ok, pdf} <- Scans.finish(ctx.company.id, sid),
             {:ok, att} <- store(ctx, %{path: pdf, file_name: name}) do
          Scans.discard(ctx.company.id, sid)
          {:ok, att}
        end

      reply(conn, ctx, result, &%{id: &1.id})
    end)
  end

  # "✓ Finished": the link stops working now, not after 10 idle minutes.
  def finish(conn, %{"token" => token}) do
    with_ctx(conn, token, fn ctx ->
      PhoneUpload.finish(token)

      # The desktop's QR modal for this target closes itself (NoteFiles).
      Phoenix.PubSub.broadcast(
        FullCircle.PubSub,
        Attachments.topic(ctx.company.id),
        {:phone_closed, ctx.target}
      )

      json(conn, %{ok: true})
    end)
  end

  # --- helpers --------------------------------------------------------------

  defp with_ctx(conn, token, fun) do
    case PhoneUpload.resolve(token) do
      {:ok, ctx} ->
        fun.(ctx)

      _ ->
        error(
          conn,
          401,
          "expired",
          gettext("This link has expired — show a new QR on the desktop.")
        )
    end
  end

  defp store(%{target: {:tray, id}} = ctx, upload),
    do: Attachments.attach_to_tray(id, upload, ctx.company, ctx.user)

  defp store(%{target: {:note, id}} = ctx, upload),
    do: Attachments.attach(%Note{id: id}, upload, ctx.company, ctx.user)

  defp reply(conn, ctx, {:ok, value}, shape),
    do: json(conn, Map.put(shape.(value), :token, ctx.token))

  defp reply(conn, _ctx, {:error, :tray_closed}, _),
    do: error(conn, 409, "closed", NoteAttachmentController.message(:tray_closed))

  defp reply(conn, _ctx, err, _)
       when err in [:not_authorise, {:error, :note_not_found}, {:error, :not_found}],
       do: error(conn, 403, "forbidden", gettext("You can't add files to this note any more."))

  defp reply(conn, _ctx, {:error, reason}, _),
    do: error(conn, 422, "invalid", NoteAttachmentController.message(reason))

  defp error(conn, status, code, msg),
    do: conn |> put_status(status) |> json(%{error: msg, code: code})

  defp target_key({kind, id}), do: "#{kind}:#{id}"

  # The phone names the PDF from its own clock ("Scan 2026-10-04 1432.pdf");
  # only a sane basename ending in .pdf is kept.
  defp pdf_name(name) when is_binary(name) do
    base =
      name |> Path.basename() |> String.replace(~r/[^\w\s\-.]/u, "") |> String.slice(0, 120)

    if String.ends_with?(base, ".pdf") and base != ".pdf", do: base, else: "Scan.pdf"
  end

  defp pdf_name(_), do: "Scan.pdf"
end
