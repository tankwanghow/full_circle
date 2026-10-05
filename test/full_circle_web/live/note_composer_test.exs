defmodule FullCircleWeb.NoteComposerTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes.Note

  # A bare LiveView hosting one composer; it records the last composer event.
  defmodule Host do
    use FullCircleWeb, :live_view

    def mount(_params, session, socket) do
      # opts keys go through String.to_existing_atom; load the module so its atoms exist
      Code.ensure_loaded!(FullCircleWeb.NoteLive.ComposerComponent)

      {:ok,
       assign(socket,
         current_company: FullCircle.Repo.get!(FullCircle.Sys.Company, session["company_id"]),
         current_user: FullCircle.Repo.get!(FullCircle.UserAccounts.User, session["user_id"]),
         opts: session["opts"] || %{},
         last: nil,
         tick: 0
       ), layout: false}
    end

    def handle_info({:composer, _id, event}, socket), do: {:noreply, assign(socket, last: event)}

    def handle_event("tick", _, socket),
      do: {:noreply, assign(socket, tick: socket.assigns.tick + 1)}

    def render(assigns) do
      ~H"""
      <button id="tick" phx-click="tick">{@tick}</button>
      <.live_component
        module={FullCircleWeb.NoteLive.ComposerComponent}
        id="c"
        current_company={@current_company}
        current_user={@current_user}
        {Map.new(@opts, fn {k, v} -> {String.to_existing_atom(k), v} end)}
      />
      <div id="last">{inspect(@last)}</div>
      """
    end
  end

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp}
  end

  defp host(conn, comp, admin, opts \\ %{}) do
    {:ok, lv, _} =
      live_isolated(conn, Host,
        session: %{"company_id" => comp.id, "user_id" => admin.id, "opts" => opts}
      )

    lv
  end

  test "posts a note, tells the host and clears itself", %{conn: conn, admin: admin, comp: comp} do
    lv = host(conn, comp, admin)
    lv |> form("#c-form", %{"note" => %{"body" => "Gate 2 lock is broken"}}) |> render_submit()

    [note] = FullCircle.Repo.all(Note)
    assert note.body == "Gate 2 lock is broken"
    assert render(lv) =~ "{:saved, :new"
    refute has_element?(lv, "#c-form textarea", "Gate 2 lock is broken")
  end

  test "blank body shows the error inside the box", %{conn: conn, admin: admin, comp: comp} do
    lv = host(conn, comp, admin)
    html = lv |> form("#c-form", %{"note" => %{"body" => ""}}) |> render_submit()
    assert html =~ "can&#39;t be blank"
    assert FullCircle.Repo.all(Note) == []
  end

  test "host re-render keeps typed text", %{conn: conn, admin: admin, comp: comp} do
    lv = host(conn, comp, admin)
    lv |> form("#c-form", %{"note" => %{"body" => "half typed"}}) |> render_change()
    lv |> element("#tick") |> render_click()
    assert has_element?(lv, "#c-form textarea", "half typed")
  end

  test "subject picked through the picker is saved", %{conn: conn, admin: admin, comp: comp} do
    c = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
    lv = host(conn, comp, admin)

    lv |> element("#c-open-picker") |> render_click()
    lv |> form("#c-picker form", %{"type" => "Contact", "terms" => "Mei"}) |> render_change()
    lv |> element("#c-picker-pick-#{c.id}") |> render_click()
    assert render(lv) =~ "Kedai Mei"

    lv |> form("#c-form", %{"note" => %{"body" => "orders every Monday"}}) |> render_submit()
    [note] = FullCircle.Repo.all(Note)
    assert {note.subject_type, note.subject_id} == {"Contact", c.id}
  end

  test "full mode: title, queued links, expanded role chips", %{
    conn: conn,
    admin: admin,
    comp: comp
  } do
    ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
    mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
    lv = host(conn, comp, admin, %{"full" => true})

    assert has_element?(lv, "label.role-chip", "manager")

    for {c, terms} <- [{ali, "Ali"}, {mei, "Mei"}] do
      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Contact", "terms" => terms}) |> render_change()
      lv |> element("#c-picker-pick-#{c.id}") |> render_click()
    end

    lv
    |> form("#c-form", %{
      "note" => %{"title" => "Welders", "body" => "both weld", "visibility" => ["manager"]}
    })
    |> render_submit()

    [note] = FullCircle.Repo.all(Note)
    assert note.title == "Welders"
    assert note.subject_id == ali.id
    assert note.visibility == ["manager"]
    assert [%{id: id}] = FullCircle.Notes.list_links(note, comp, admin)
    assert id == mei.id
  end

  test "fixed subject: no picker, note is about the record", %{
    conn: conn,
    admin: admin,
    comp: comp
  } do
    c = contact_fixture(comp, admin)
    lv = host(conn, comp, admin, %{"fixed_subject" => {"Contact", c.id}})
    refute has_element?(lv, "#c-open-picker")
    lv |> form("#c-form", %{"note" => %{"body" => "pays late"}}) |> render_submit()
    [note] = FullCircle.Repo.all(Note)
    assert {note.subject_type, note.subject_id} == {"Contact", c.id}
  end

  test "Private default and no role chips (task panels)", %{conn: conn, admin: admin, comp: comp} do
    lv =
      host(conn, comp, admin, %{
        "roles_open" => true,
        "roles" => false,
        "default_visibility" => ["admin"],
        "hint" => "Everyone who can see this task can read its notes."
      })

    assert has_element?(lv, "#c-visibility-private[data-selected]")
    refute has_element?(lv, "label.role-chip", "manager")
    assert render(lv) =~ "Everyone who can see this task can read its notes."
  end

  describe "edit mode" do
    defp edit_host(conn, comp, admin, note) do
      note = FullCircle.Notes.get_note(note.id, comp, admin)

      host(conn, comp, admin, %{
        "mode" => :edit,
        "note" => note,
        "full" => true,
        "cancellable" => true
      })
    end

    test "prefills and saves, writing one version", %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      note =
        note_fixture(comp, admin, %{
          "title" => "T",
          "body" => "v1",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      lv = edit_host(conn, comp, admin, note)
      assert has_element?(lv, "#c-form textarea", "v1")
      assert has_element?(lv, ~s{#c_title[value="T"]})
      assert render(lv) =~ "Ah Seng"
      assert has_element?(lv, "label.role-chip[data-selected]", "manager")

      lv |> form("#c-form", %{"note" => %{"body" => "v2"}}) |> render_submit()
      assert render(lv) =~ "{:saved, :edit"
      assert FullCircle.Repo.get!(Note, note.id).body == "v2"
      assert [%{body: "v1"}] = FullCircle.Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "a stale save keeps the typed text and warns", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      lv = edit_host(conn, comp, admin, note)
      {:ok, _} = FullCircle.Notes.update_note(note, %{"body" => "someone else"}, comp, admin)

      html =
        lv
        |> form("#c-form", %{"note" => %{"title" => "my title", "body" => "my text"}})
        |> render_submit()

      assert html =~ "someone else changed this note"
      assert has_element?(lv, "#c-form textarea", "my text")
      assert has_element?(lv, ~s{#c_title[value="my title"]})
    end

    test "cancel tells the host and saves nothing", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      lv = edit_host(conn, comp, admin, note)
      lv |> form("#c-form", %{"note" => %{"body" => "draft"}}) |> render_change()
      lv |> element("#c-cancel") |> render_click()
      assert render(lv) =~ ":cancelled"
      assert FullCircle.Repo.get!(Note, note.id).body == "v1"
    end

    test "links on a saved note apply straight away", %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})

      note =
        note_fixture(comp, admin, %{
          "body" => "b",
          "subject_type" => "Contact",
          "subject_id" => ali.id
        })

      lv = edit_host(conn, comp, admin, note)
      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Contact", "terms" => "Mei"}) |> render_change()
      lv |> element("#c-picker-pick-#{mei.id}") |> render_click()

      # render first: the pick arrives via send_update, so wait for it
      assert render(lv) =~ "Kedai Mei"
      assert [link] = FullCircle.Notes.list_links(note, comp, admin)

      lv |> element("#remove-link-#{link.link_id}") |> render_click()
      assert FullCircle.Notes.list_links(note, comp, admin) == []
      refute render(lv) =~ "Kedai Mei"
    end

    test "a malformed link id is ignored", %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})

      note =
        note_fixture(comp, admin, %{
          "body" => "b",
          "subject_type" => "Contact",
          "subject_id" => ali.id
        })

      {:ok, _} = FullCircle.Notes.add_link(note, "Contact", mei.id, comp, admin)
      lv = edit_host(conn, comp, admin, note)

      [link] = FullCircle.Notes.list_links(note, comp, admin)

      # the click value overrides phx-value-id, simulating a tampered client
      lv |> element("#remove-link-#{link.link_id}") |> render_click(%{"id" => "x"})

      assert render(lv) =~ "Kedai Mei"
      assert [_] = FullCircle.Notes.list_links(note, comp, admin)
    end

    test "linking a note to itself says why", %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})

      note =
        note_fixture(comp, admin, %{
          "body" => "self",
          "subject_type" => "Contact",
          "subject_id" => ali.id
        })

      lv = edit_host(conn, comp, admin, note)
      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Note", "terms" => "self"}) |> render_change()
      lv |> element("#c-picker-pick-#{note.id}") |> render_click()
      assert render(lv) =~ "cannot link to itself"
    end

    test "clearing the subject saves the note about nothing", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      ali = contact_fixture(comp, admin)

      note =
        note_fixture(comp, admin, %{
          "body" => "b",
          "subject_type" => "Contact",
          "subject_id" => ali.id
        })

      lv = edit_host(conn, comp, admin, note)
      lv |> element("#c-clear-subject") |> render_click()
      lv |> form("#c-form", %{"note" => %{"body" => "b2"}}) |> render_submit()
      assert FullCircle.Repo.get!(Note, note.id).subject_id == nil
    end
  end

  test "compact box: the visibility pill stays while the chips are open and folds them",
       %{conn: conn, comp: comp, admin: admin} do
    lv = host(conn, comp, admin)
    assert has_element?(lv, "#c-roles-toggle", "Everyone")
    refute has_element?(lv, "#c-visibility-everyone")

    lv |> element("#c-roles-toggle") |> render_click()
    assert has_element?(lv, "#c-visibility-everyone")
    assert has_element?(lv, "#c-roles-toggle", "Everyone")

    lv |> element("#c-roles-toggle") |> render_click()
    refute has_element?(lv, "#c-visibility-everyone")
  end

  test "a box that opens with the chips shown has no pill",
       %{conn: conn, comp: comp, admin: admin} do
    lv = host(conn, comp, admin, %{"roles_open" => true})
    assert has_element?(lv, "#c-visibility-everyone")
    refute has_element?(lv, "#c-roles-toggle")
  end

  describe "reply mode" do
    test "posts a reply to the root with no subject or visibility choices", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      root = note_fixture(comp, admin, %{"body" => "root", "visibility" => ["manager"]})
      lv = host(conn, comp, admin, %{"reply_to" => root})

      refute has_element?(lv, "#c-open-picker")
      refute has_element?(lv, "#c-roles-toggle")
      refute has_element?(lv, "label.role-chip")
      assert has_element?(lv, "#c-reply-scope")

      lv |> form("#c-form", %{"note" => %{"body" => "agreed"}}) |> render_submit()
      reply = FullCircle.Repo.get_by!(Note, body: "agreed")
      assert reply.reply_to_id == root.id
      assert reply.visibility == ["manager"]
    end

    test "a refused reply says why", %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "root"})
      lv = host(conn, comp, admin, %{"reply_to" => root})
      {:ok, _} = FullCircle.Notes.delete_note(root, comp, admin)

      html = lv |> form("#c-form", %{"note" => %{"body" => "too late"}}) |> render_submit()
      assert html =~ "can&#39;t be replied to"
      refute FullCircle.Repo.get_by(Note, body: "too late")
    end

    test "editing a reply hides subject and visibility; picks become links", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      root = note_fixture(comp, admin, %{"body" => "root"})

      {:ok, r} =
        FullCircle.Notes.create_note(%{"body" => "r", "reply_to_id" => root.id}, comp, admin)

      r = FullCircle.Notes.get_note(r.id, comp, admin)

      lv = host(conn, comp, admin, %{"mode" => :edit, "note" => r, "full" => true})
      refute has_element?(lv, "label.role-chip")
      assert has_element?(lv, "#c-reply-scope")

      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Contact", "terms" => "Mei"}) |> render_change()
      lv |> element("#c-picker-pick-#{mei.id}") |> render_click()
      render(lv)

      assert [%{id: id}] = FullCircle.Notes.list_links(r, comp, admin)
      assert id == mei.id
      assert FullCircle.Repo.get!(Note, r.id).subject_id == nil
    end
  end

  describe "error placement" do
    test "blank body shows its error under the body", %{conn: conn, admin: admin, comp: comp} do
      lv = host(conn, comp, admin)
      lv |> form("#c-form", %{"note" => %{"body" => ""}}) |> render_submit()
      assert has_element?(lv, "#c-body-errors", "can't be blank")
    end

    test "a title over 120 characters shows its error under the title", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      lv = host(conn, comp, admin, %{"full" => true})

      lv
      |> form("#c-form", %{"note" => %{"title" => String.duplicate("x", 121), "body" => "b"}})
      |> render_submit()

      assert has_element?(lv, "#c-title-errors", "should be at most 120 character")
      assert FullCircle.Repo.all(Note) == []
    end

    test "typing a title first does not flag the untouched body", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      lv = host(conn, comp, admin, %{"full" => true})

      # What the browser sends: an input not yet touched comes with `_unused_`.
      lv
      |> element("#c-form")
      |> render_change(%{"note" => %{"title" => "Gate", "body" => "", "_unused_body" => ""}})

      refute has_element?(lv, "#c-body-errors")

      lv |> element("#c-form") |> render_change(%{"note" => %{"title" => "Gate", "body" => ""}})
      assert has_element?(lv, "#c-body-errors", "can't be blank")
    end

    test "a link error sits by the chips and clears on the next edit", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})

      note =
        note_fixture(comp, admin, %{
          "body" => "self",
          "subject_type" => "Contact",
          "subject_id" => ali.id
        })

      lv = edit_host(conn, comp, admin, note)
      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Note", "terms" => "self"}) |> render_change()
      lv |> element("#c-picker-pick-#{note.id}") |> render_click()
      assert has_element?(lv, "#c-error", "cannot link to itself")

      lv |> form("#c-form", %{"note" => %{"body" => "self, edited"}}) |> render_change()
      refute has_element?(lv, "#c-error")
    end
  end
end
