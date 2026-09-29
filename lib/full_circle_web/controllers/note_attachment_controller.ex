defmodule FullCircleWeb.NoteAttachmentController do
  @moduledoc """
  Plain-HTTP upload and download for note attachments. Uploads go over HTTP,
  not the LiveView socket, because a phone backgrounding the page during a
  camera pick kills the socket and loses a socket upload.
  """
  use FullCircleWeb, :controller

  alias FullCircle.Notes.{Attachments, Note}

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

  def show(conn, %{"id" => id}) do
    case Attachments.get_readable(id, conn.assigns.current_company, conn.assigns.current_user) do
      nil ->
        send_resp(conn, 404, "not found")

      att ->
        abs = Attachments.abs_path(att)

        if File.exists?(abs) do
          conn
          |> put_resp_content_type(att.content_type, nil)
          |> put_resp_header(
            "content-disposition",
            ~s(inline; filename="#{safe_name(att.file_name)}")
          )
          |> send_file(200, abs)
        else
          send_resp(conn, 404, "not found")
        end
    end
  end

  defp message(:too_large), do: gettext("File is larger than 10 MB.")

  defp message(:unsupported_type),
    do: gettext("Only JPEG, PNG, WebP images and PDF files are allowed.")

  defp message(:not_found), do: gettext("File could not be read.")
  defp message(_), do: gettext("Upload failed.")

  defp safe_name(name), do: String.replace(name, ~r/["\r\n\\]/, "_")
end
