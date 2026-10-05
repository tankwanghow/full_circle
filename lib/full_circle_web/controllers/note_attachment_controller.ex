defmodule FullCircleWeb.NoteAttachmentController do
  @moduledoc """
  Plain-HTTP upload and download for note attachments. Uploads go over HTTP,
  not the LiveView socket, because a phone backgrounding the page during a
  camera pick kills the socket and loses a socket upload.
  """
  use FullCircleWeb, :controller

  alias FullCircle.Notes.{Attachments, Note, Trays}

  def create(conn, %{"note_id" => note_id, "file" => %Plug.Upload{} = file} = params) do
    company = conn.assigns.current_company
    user = conn.assigns.current_user

    # attach/4 loads the note itself (visibility included); no need to fetch
    # it here first.
    case Attachments.attach(%Note{id: note_id}, upload(file, params), company, user) do
      {:ok, att} ->
        json(conn, %{ok: true, id: att.id})

      {:error, :note_not_found} ->
        conn |> put_status(404) |> json(%{error: gettext("Note not found.")})

      :not_authorise ->
        conn |> put_status(403) |> json(%{error: gettext("Not Authorise.")})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: message(reason)})
    end
  end

  def create(conn, _params),
    do: conn |> put_status(422) |> json(%{error: gettext("No file received.")})

  # The write box's 📎 / drop / paste: into its tray, created on first use.
  def create_tray(conn, %{"tray_id" => tray_id, "file" => %Plug.Upload{} = file} = params) do
    company = conn.assigns.current_company
    user = conn.assigns.current_user

    with {:ok, _tray} <- Trays.open(tray_id, company, user),
         {:ok, att} <- Attachments.attach_to_tray(tray_id, upload(file, params), company, user) do
      json(conn, %{ok: true, id: att.id})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: gettext("Not found.")})

      :not_authorise ->
        conn |> put_status(403) |> json(%{error: gettext("Not Authorise.")})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: message(reason)})
    end
  end

  def create_tray(conn, _params),
    do: conn |> put_status(422) |> json(%{error: gettext("No file received.")})

  @doc """
  The upload map `Attachments` stores. `kind` ("video"/"audio") is the
  recorder's hint for a WebM or mp4, which can hold either.
  """
  def upload(%Plug.Upload{} = file, params),
    do: %{path: file.path, file_name: file.filename, kind: params["kind"]}

  def show(conn, %{"id" => id} = params) do
    att = Attachments.get_readable(id, conn.assigns.current_company, conn.assigns.current_user)

    file =
      cond do
        is_nil(att) -> nil
        params["variant"] == "thumb" -> Attachments.thumb_file(att)
        true -> {:ok, Attachments.abs_path(att), att.content_type}
      end

    case file do
      {:ok, path, type} ->
        if File.exists?(path) do
          conn
          |> put_resp_content_type(type, nil)
          |> put_resp_header(
            "content-disposition",
            ~s(inline; filename="#{safe_name(att.file_name)}")
          )
          |> send_ranged(path)
        else
          send_resp(conn, 404, "not found")
        end

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  def message(:too_large), do: gettext("File is larger than 10 MB.")

  def message({:too_large, max}),
    do: gettext("File is larger than %{mb} MB.", mb: div(max, 1_000_000))

  def message(:unsupported_type),
    do: gettext("Only JPEG, PNG, WebP images, PDF files and recordings are allowed.")

  def message(:not_found), do: gettext("File could not be read.")
  def message(:tray_closed), do: gettext("This note was closed on the desktop.")
  def message(:no_pages), do: gettext("Take at least one page.")
  def message(:too_many_pages), do: gettext("Up to 30 pages per PDF — finish this one first.")
  def message(:not_jpeg), do: gettext("That page is not a photo. Take it again.")
  def message(:bad_page), do: gettext("A page could not be read. Retake it.")
  def message(_), do: gettext("Upload failed.")

  # A single byte range, because iPhone Safari will not play a video without
  # one and every browser needs one to seek. Several ranges or a malformed
  # header get the whole file (a server may ignore Range); a start past the
  # end is 416.
  defp send_ranged(conn, path) do
    size = File.stat!(path).size
    conn = put_resp_header(conn, "accept-ranges", "bytes")

    case byte_range(get_req_header(conn, "range"), size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      :full ->
        send_file(conn, 200, path)
    end
  end

  defp byte_range(["bytes=" <> spec], size) do
    case String.split(String.trim(spec), "-") do
      [first, last] -> resolve(digits(first), digits(last), size)
      _ -> :full
    end
  end

  defp byte_range(_, _), do: :full

  # bytes=-n: the last n bytes.
  defp resolve(:open, n, size) when is_integer(n) do
    if n > 0 and size > 0, do: {max(size - n, 0), size - 1}, else: :unsatisfiable
  end

  defp resolve(first, last, size)
       when is_integer(first) and (last == :open or (is_integer(last) and last >= first)) do
    cond do
      first >= size -> :unsatisfiable
      last == :open -> {first, size - 1}
      true -> {first, min(last, size - 1)}
    end
  end

  # Junk, or an end before the start: not a range.
  defp resolve(_, _, _), do: :full

  defp digits(""), do: :open

  defp digits(s) do
    if s =~ ~r/\A\d{1,18}\z/, do: String.to_integer(s), else: nil
  end

  defp safe_name(name), do: String.replace(name, ~r/["\r\n\\]/, "_")
end
