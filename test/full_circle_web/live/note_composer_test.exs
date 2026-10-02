defmodule FullCircleWeb.NoteComposerTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Notes.Note

  # A bare LiveView hosting one composer; it records the last composer event.
  defmodule Host do
    use FullCircleWeb, :live_view

    def mount(_params, session, socket) do
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
end
