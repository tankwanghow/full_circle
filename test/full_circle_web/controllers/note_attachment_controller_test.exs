defmodule FullCircleWeb.NoteAttachmentControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes.Attachments

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    note = note_fixture(comp, admin)
    %{conn: conn, admin: admin, comp: comp, note: note}
  end

  defp upload(path, name),
    do: %Plug.Upload{path: path, filename: name, content_type: "application/octet-stream"}

  test "uploads a file for a note the user can edit", %{
    conn: conn,
    admin: admin,
    comp: comp,
    note: note
  } do
    conn =
      conn
      |> log_in_user(admin)
      |> post(~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{
        "file" => upload(jpeg_file(), "p.jpg")
      })

    assert %{"ok" => true, "id" => _} = json_response(conn, 200)
  end

  test "rejects an unsupported file with a message", %{
    conn: conn,
    admin: admin,
    comp: comp,
    note: note
  } do
    conn =
      conn
      |> log_in_user(admin)
      |> post(~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{
        "file" => upload(text_file(), "x.jpg")
      })

    assert %{"error" => msg} = json_response(conn, 422)
    assert msg =~ "JPEG"
  end

  test "a clerk cannot upload to someone else's note", %{
    conn: conn,
    admin: admin,
    comp: comp,
    note: note
  } do
    clerk = user_with_role(comp, admin, "clerk")

    conn =
      conn
      |> log_in_user(clerk)
      |> post(~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{
        "file" => upload(jpeg_file(), "p.jpg")
      })

    assert json_response(conn, 403)
  end

  test "download serves the file with its sniffed type", %{
    conn: conn,
    admin: admin,
    comp: comp,
    note: note
  } do
    {:ok, att} = Attachments.attach(note, %{path: jpeg_file(), file_name: "p.jpg"}, comp, admin)
    conn = conn |> log_in_user(admin) |> get(~p"/companies/#{comp.id}/note_attachments/#{att.id}")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
  end

  test "download of a restricted note's file is 404 for an outsider", %{
    conn: conn,
    admin: admin,
    comp: comp
  } do
    hidden = note_fixture(comp, admin, %{"visibility" => ["manager"]})
    {:ok, att} = Attachments.attach(hidden, %{path: jpeg_file(), file_name: "p.jpg"}, comp, admin)
    clerk = user_with_role(comp, admin, "clerk")
    conn = conn |> log_in_user(clerk) |> get(~p"/companies/#{comp.id}/note_attachments/#{att.id}")
    assert response(conn, 404)
  end

  @tag :pdftoppm
  test "?variant=thumb serves a PDF's first page as a JPEG", %{
    conn: conn,
    admin: admin,
    comp: comp,
    note: note
  } do
    {:ok, att} =
      Attachments.attach(note, %{path: real_pdf_file(), file_name: "c.pdf"}, comp, admin)

    conn =
      conn
      |> log_in_user(admin)
      |> get(~p"/companies/#{comp.id}/note_attachments/#{att.id}?variant=thumb")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
  end

  @tag :pdftoppm
  test "a PDF with no preview gives 404 for the thumb, the file itself still downloads",
       %{conn: conn, admin: admin, comp: comp, note: note} do
    {:ok, att} = Attachments.attach(note, %{path: pdf_file(), file_name: "bad.pdf"}, comp, admin)
    conn = log_in_user(conn, admin)

    assert response(
             get(conn, ~p"/companies/#{comp.id}/note_attachments/#{att.id}?variant=thumb"),
             404
           )

    assert response(get(conn, ~p"/companies/#{comp.id}/note_attachments/#{att.id}"), 200)
  end

  test "a thumb of a restricted note's file is 404 for an outsider", %{
    conn: conn,
    admin: admin,
    comp: comp
  } do
    hidden = note_fixture(comp, admin, %{"visibility" => ["manager"]})
    {:ok, att} = Attachments.attach(hidden, %{path: pdf_file(), file_name: "c.pdf"}, comp, admin)
    clerk = user_with_role(comp, admin, "clerk")

    conn =
      build_conn()
      |> log_in_user(clerk)
      |> get(~p"/companies/#{comp.id}/note_attachments/#{att.id}?variant=thumb")

    assert response(conn, 404)
  end

  test "a logged-in tray upload opens the tray on first use", %{
    conn: conn,
    admin: admin,
    comp: comp
  } do
    tray_id = Ecto.UUID.generate()

    conn =
      conn
      |> log_in_user(admin)
      |> post(~p"/companies/#{comp.id}/note_trays/#{tray_id}/files", %{
        "file" => upload(jpeg_file(), "p.jpg")
      })

    assert %{"ok" => true, "id" => _} = json_response(conn, 200)
    assert [_] = FullCircle.Notes.Trays.list(tray_id, comp, admin)
  end
end
