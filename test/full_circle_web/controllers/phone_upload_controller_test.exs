defmodule FullCircleWeb.PhoneUploadControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes
  alias FullCircle.Notes.{Scans, Trays}
  alias FullCircleWeb.PhoneUpload

  setup do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    note = note_fixture(comp, admin, %{"title" => "Bank letter"})
    tray = tray_fixture(comp, admin)
    %{admin: admin, comp: comp, note: note, tray: tray}
  end

  defp upload(path, name),
    do: %Plug.Upload{path: path, filename: name, content_type: "application/octet-stream"}

  defp tok(ctx, target), do: PhoneUpload.sign(target, "label", ctx.comp.id, ctx.admin.id)

  test "the page renders for a good token and says expired otherwise", ctx do
    html = ctx.conn |> get(~p"/up/#{tok(ctx, {:note, ctx.note.id})}") |> html_response(200)
    assert html =~ "label"
    assert html =~ "phone_upload.js"
    refute html =~ "phx-socket"
    assert ctx.conn |> get(~p"/up/garbage") |> html_response(410) =~ "expired"
  end

  test "a file goes into the tray and a fresh token comes back", ctx do
    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:tray, ctx.tray.id})}/files", %{
        "file" => upload(jpeg_file(), "wa.jpg")
      })

    assert %{"id" => _, "token" => fresh} = json_response(conn, 200)
    assert is_binary(fresh)
    assert [%{file_name: "wa.jpg"}] = Trays.list(ctx.tray.id, ctx.comp, ctx.admin)
  end

  test "a file goes straight onto a saved note", ctx do
    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:note, ctx.note.id})}/files", %{
        "file" => upload(pdf_file(), "letter.pdf")
      })

    assert %{"id" => _} = json_response(conn, 200)

    assert [%{file_name: "letter.pdf"}] =
             Notes.get_note(ctx.note.id, ctx.comp, ctx.admin).attachments
  end

  test "a cancelled tray answers closed", ctx do
    Trays.cancel(ctx.tray.id, ctx.comp, ctx.admin)

    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:tray, ctx.tray.id})}/files", %{
        "file" => upload(jpeg_file(), "late.jpg")
      })

    assert %{"code" => "closed"} = json_response(conn, 409)
  end

  test "a note the user may no longer edit answers forbidden", ctx do
    clerk = user_with_role(ctx.comp, ctx.admin, "clerk")
    token = PhoneUpload.sign({:note, ctx.note.id}, "x", ctx.comp.id, clerk.id)
    conn = post(ctx.conn, ~p"/up/#{token}/files", %{"file" => upload(jpeg_file(), "a.jpg")})
    assert %{"code" => "forbidden"} = json_response(conn, 403)
  end

  test "an expired token answers expired", ctx do
    conn = post(ctx.conn, ~p"/up/garbage/files", %{"file" => upload(jpeg_file(), "a.jpg")})
    assert %{"code" => "expired"} = json_response(conn, 401)
  end

  test "a wrong file type is a per-file error", ctx do
    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:tray, ctx.tray.id})}/files", %{
        "file" => upload(text_file(), "x.jpg")
      })

    assert %{"code" => "invalid", "error" => msg} = json_response(conn, 422)
    assert msg =~ "JPEG"
  end

  test "scan: pages, retake, state, done → one PDF in the tray", ctx do
    t = tok(ctx, {:tray, ctx.tray.id})
    sid = Ecto.UUID.generate()

    for _ <- 1..2 do
      conn =
        post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/pages", %{
          "file" => upload(real_jpeg_file(:rgb), "p.jpg")
        })

      assert %{"pages" => _} = json_response(conn, 200)
    end

    assert %{"pages" => 1} =
             ctx.conn |> delete(~p"/up/#{t}/scans/#{sid}/pages/last") |> json_response(200)

    assert %{"pages" => 1, "label" => "label"} =
             ctx.conn |> get(~p"/up/#{t}/state?scan_id=#{sid}") |> json_response(200)

    conn = post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/done", %{"name" => "Scan 2026-10-04 1432.pdf"})
    assert %{"id" => _} = json_response(conn, 200)

    assert [%{file_name: "Scan 2026-10-04 1432.pdf", content_type: "application/pdf"}] =
             Trays.list(ctx.tray.id, ctx.comp, ctx.admin)

    assert Scans.count(ctx.comp.id, sid) == 0
  end

  test "scan: a non-JPEG page is refused, done with no pages is refused", ctx do
    t = tok(ctx, {:tray, ctx.tray.id})
    sid = Ecto.UUID.generate()

    conn =
      post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/pages", %{"file" => upload(pdf_file(), "p.pdf")})

    assert %{"code" => "invalid"} = json_response(conn, 422)
    conn = post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/done", %{"name" => "x.pdf"})
    assert %{"code" => "invalid", "error" => msg} = json_response(conn, 422)
    assert msg =~ "page"
  end

  test "a tray file is served to its owner (thumbnails in the box) and to nobody else", ctx do
    {:ok, att} =
      FullCircle.Notes.Attachments.attach_to_tray(
        ctx.tray.id,
        %{path: jpeg_file(), file_name: "t.jpg"},
        ctx.comp,
        ctx.admin
      )

    url = FullCircle.Notes.Attachments.url(att)
    assert ctx.conn |> log_in_user(ctx.admin) |> get(url) |> response(200)

    manager = user_with_role(ctx.comp, ctx.admin, "manager")
    assert build_conn() |> log_in_user(manager) |> get(url) |> response(404)
  end

  test "Finished ends the link: later uploads answer expired", ctx do
    t = tok(ctx, {:tray, ctx.tray.id})
    assert %{"ok" => true} = ctx.conn |> post(~p"/up/#{t}/finish") |> json_response(200)

    conn = post(ctx.conn, ~p"/up/#{t}/files", %{"file" => upload(jpeg_file(), "a.jpg")})
    assert %{"code" => "expired"} = json_response(conn, 401)
    assert ctx.conn |> get(~p"/up/#{t}") |> html_response(410) =~ "expired"
  end
end
