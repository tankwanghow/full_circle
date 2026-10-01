defmodule FullCircle.CommandPalette.NoteSearchTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.CommandPalette

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  defp notes(hits), do: Enum.filter(hits, &(&1.kind == :note))
  defp fallback(hits), do: Enum.find(hits, &(&1.kind == :note_search))

  describe "note prefix" do
    test "`note <words>` returns matching notes, newest first, linking to the note", %{
      admin: admin,
      company: company
    } do
      old = note_fixture(company, admin, %{"title" => "Maize moisture", "body" => "silo 2"})
      new = note_fixture(company, admin, %{"body" => "maize moisture high again\nsecond line"})
      _other = note_fixture(company, admin, %{"body" => "soybean price"})

      hits = CommandPalette.search(company, admin, "note maize moisture")
      found = notes(hits)

      assert Enum.map(found, & &1.doc_id) |> Enum.sort() == Enum.sort([old.id, new.id])

      by_id = Map.new(found, &{&1.doc_id, &1})
      assert by_id[old.id].doc_no == "Maize moisture"
      # Untitled note shows its first line
      assert by_id[new.id].doc_no == "maize moisture high again"
      assert by_id[new.id].label == "Note"
      assert by_id[new.id].path == "/companies/#{company.id}/notes/#{new.id}"
      assert by_id[new.id].subtitle =~ admin.email |> String.split("@") |> hd()

      # Prefix mode searches notes only
      assert Enum.all?(hits, &(&1.kind in [:note, :note_search]))
    end

    test "`notes` works too and the prefix is case-insensitive", %{
      admin: admin,
      company: company
    } do
      n = note_fixture(company, admin, %{"body" => "broken weighbridge"})
      assert [%{doc_id: id}] = notes(CommandPalette.search(company, admin, "Notes weighbridge"))
      assert id == n.id
      assert [%{doc_id: ^id}] = notes(CommandPalette.search(company, admin, "NOTE weighbridge"))
    end

    test "subject record title shows in the subtitle", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin, %{"name" => "Swee Lee Farm"})

      note_fixture(company, admin, %{
        "body" => "pays late",
        "subject_type" => "Contact",
        "subject_id" => contact.id
      })

      assert [hit] = notes(CommandPalette.search(company, admin, "note pays late"))
      assert hit.subtitle =~ "Swee Lee Farm"
    end

    test "visibility is enforced", %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")

      note_fixture(company, admin, %{
        "body" => "manager eyes only budget",
        "visibility" => ["manager"]
      })

      note_fixture(company, admin, %{"body" => "everyone budget"})

      found = notes(CommandPalette.search(company, clerk, "note budget"))
      assert Enum.map(found, & &1.doc_no) == ["everyone budget"]
      assert length(notes(CommandPalette.search(company, admin, "note budget"))) == 2
    end

    test "guest without :view_notes gets nothing", %{admin: admin, company: company} do
      guest = user_with_role(company, admin, "guest")
      note_fixture(company, admin, %{"body" => "secret plan"})

      assert CommandPalette.search(company, guest, "note secret") == []
    end

    test "prefix alone (no words) does not search", %{admin: admin, company: company} do
      note_fixture(company, admin, %{"body" => "anything"})
      assert notes(CommandPalette.search(company, admin, "note")) == []
      assert notes(CommandPalette.search(company, admin, "note   ")) == []
    end
  end

  describe "search-notes fallback row" do
    test "ordinary searches end with a link to the Notes page search", %{
      admin: admin,
      company: company
    } do
      hits = CommandPalette.search(company, admin, "swee lee")
      row = fallback(hits)

      assert List.last(hits) == row
      assert row.path == "/companies/#{company.id}/notes?search%5Bterms%5D=swee+lee"
      assert row.doc_no =~ "swee lee"
    end

    test "prefix mode ends with the same link for the words after the prefix", %{
      admin: admin,
      company: company
    } do
      row = fallback(CommandPalette.search(company, admin, "note swee lee"))
      assert row.path == "/companies/#{company.id}/notes?search%5Bterms%5D=swee+lee"
    end

    test "no fallback for create actions or users without :view_notes", %{
      admin: admin,
      company: company
    } do
      refute fallback(CommandPalette.search(company, admin, "newinv"))

      guest = user_with_role(company, admin, "guest")
      refute fallback(CommandPalette.search(company, guest, "swee lee"))
    end
  end
end
