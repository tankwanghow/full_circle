defmodule FullCircleWeb.NoteAttachmentController do
  @moduledoc """
  Plain-HTTP upload and download for note attachments. Uploads go over HTTP,
  not the LiveView socket, because a phone backgrounding the page during a
  camera pick kills the socket and loses a socket upload.
  """
  use FullCircleWeb, :controller

  alias FullCircle.Notes.{Attachments, Note, Trays}

  def create(conn, %{"note_id" => note_id, "file" => %Plug.Upload{} = file}) do
    company = conn.assigns.current_company
    user = conn.assigns.current_user

    # attach/4 loads the note itself (visibility included); no need to fetch
    # it here first.
    case Attachments.attach(
           %Note{id: note_id},
           %{path: file.path, file_name: file.filename},
           company,
           user
         ) do
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
  def create_tray(conn, %{"tray_id" => tray_id, "file" => %Plug.Upload{} = file}) do
    company = conn.assigns.current_company
    user = conn.assigns.current_user

    with {:ok, _tray} <- Trays.open(tray_id, company, user),
         {:ok, att} <-
           Attachments.attach_to_tray(
             tray_id,
             %{path: file.path, file_name: file.filename},
             company,
             user
           ) do
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
          |> send_file(200, path)
        else
          send_resp(conn, 404, "not found")
        end

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  def message(:too_large), do: gettext("File is larger than 10 MB.")

  def message(:unsupported_type),
    do: gettext("Only JPEG, PNG, WebP images and PDF files are allowed.")

  def message(:not_found), do: gettext("File could not be read.")
  def message(:tray_closed), do: gettext("This note was closed on the desktop.")
  def message(:no_pages), do: gettext("Take at least one page.")
  def message(:too_many_pages), do: gettext("Up to 30 pages per PDF — finish this one first.")
  def message(:not_jpeg), do: gettext("That page is not a photo. Take it again.")
  def message(:bad_page), do: gettext("A page could not be read. Retake it.")
  def message(_), do: gettext("Upload failed.")

  defp safe_name(name), do: String.replace(name, ~r/["\r\n\\]/, "_")
end
