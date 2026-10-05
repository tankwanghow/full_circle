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

  test "the recorder's kind field types a WebM, on a note and in a tray", %{
    conn: conn,
    admin: admin,
    comp: comp,
    note: note
  } do
    conn = log_in_user(conn, admin)

    resp =
      post(conn, ~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{
        "file" => upload(webm_file(), "Audio.webm"),
        "kind" => "audio"
      })

    assert %{"id" => id} = json_response(resp, 200)
    assert FullCircle.Repo.get!(FullCircle.Notes.NoteAttachment, id).content_type == "audio/webm"

    tray_id = Ecto.UUID.generate()

    resp =
      post(conn, ~p"/companies/#{comp.id}/note_trays/#{tray_id}/files", %{
        "file" => upload(webm_file(), "Audio.webm"),
        "kind" => "audio"
      })

    assert %{"ok" => true} = json_response(resp, 200)
    assert [%{content_type: "audio/webm"}] = FullCircle.Notes.Trays.list(tray_id, comp, admin)
  end

  test "an oversize recording names its own kind's limit", %{
    conn: conn,
    admin: admin,
    comp: comp,
    note: note
  } do
    conn =
      conn
      |> log_in_user(admin)
      |> post(~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{
        "file" => upload(webm_file(5_000_001), "Audio.webm"),
        "kind" => "audio"
      })

    assert %{"error" => msg} = json_response(conn, 422)
    assert msg =~ "5 MB"
  end

  describe "Range requests" do
    setup %{conn: conn, admin: admin, comp: comp, note: note} do
      # An mp4 header and padding, then 32 known bytes at the end.
      path = mp4_file("isom", 56)
      File.write!(path, :binary.copy("ABCDEFGH", 4), [:append])
      body = File.read!(path)
      {:ok, att} = Attachments.attach(note, %{path: path, file_name: "v.mp4"}, comp, admin)
      url = ~p"/companies/#{comp.id}/note_attachments/#{att.id}"
      %{conn: log_in_user(conn, admin), url: url, body: body}
    end

    defp ranged(conn, url, range),
      do: conn |> put_req_header("range", range) |> get(url)

    test "no Range: the whole file, saying ranges are accepted", %{
      conn: conn,
      url: url,
      body: body
    } do
      conn = get(conn, url)
      assert response(conn, 200) == body
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-type") |> hd() =~ "video/mp4"
    end

    test "bytes=a-b is a 206 with that slice", %{conn: conn, url: url, body: body} do
      conn = ranged(conn, url, "bytes=10-19")
      assert response(conn, 206) == binary_part(body, 10, 10)
      assert get_resp_header(conn, "content-range") == ["bytes 10-19/#{byte_size(body)}"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "an end past EOF is clipped", %{conn: conn, url: url, body: body} do
      size = byte_size(body)
      conn = ranged(conn, url, "bytes=90-5000")
      assert response(conn, 206) == binary_part(body, 90, size - 90)
      assert get_resp_header(conn, "content-range") == ["bytes 90-#{size - 1}/#{size}"]
    end

    test "open range bytes=a-", %{conn: conn, url: url, body: body} do
      size = byte_size(body)
      conn = ranged(conn, url, "bytes=0-")
      assert response(conn, 206) == body
      assert get_resp_header(conn, "content-range") == ["bytes 0-#{size - 1}/#{size}"]
    end

    test "suffix range bytes=-n", %{conn: conn, url: url, body: body} do
      size = byte_size(body)
      conn = ranged(conn, url, "bytes=-8")
      assert response(conn, 206) == "ABCDEFGH"
      assert get_resp_header(conn, "content-range") == ["bytes #{size - 8}-#{size - 1}/#{size}"]
    end

    test "a start beyond EOF is 416", %{conn: conn, url: url, body: body} do
      conn = ranged(conn, url, "bytes=#{byte_size(body)}-")
      assert response(conn, 416)
      assert get_resp_header(conn, "content-range") == ["bytes */#{byte_size(body)}"]
    end

    test "multiple ranges or junk get the whole file", %{conn: conn, url: url, body: body} do
      assert response(ranged(conn, url, "bytes=0-1,5-6"), 200) == body
      assert response(ranged(conn, url, "bytes=abc"), 200) == body
      assert response(ranged(conn, url, "items=0-5"), 200) == body
      assert response(ranged(conn, url, "bytes=9-3"), 200) == body
    end
  end
end
