defmodule FullCircle.NotesTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures

  setup do
    billing_setup()
  end

  describe "notes authorization" do
    test_authorise_to(:view_notes, [
      "admin",
      "manager",
      "supervisor",
      "cashier",
      "clerk",
      "auditor"
    ])

    test_authorise_to(:create_note, ["admin", "manager", "supervisor", "cashier", "clerk"])
    test_authorise_to(:edit_others_note, ["admin", "manager"])
    test_authorise_to(:delete_others_note, ["admin", "manager"])
  end

  alias FullCircle.Notes.Note

  describe "Note.changeset/2" do
    test "body is required and title is capped at 120" do
      cs = Note.changeset(%Note{}, %{"body" => "", "title" => String.duplicate("x", 121)})
      assert %{body: ["can't be blank"], title: [_]} = errors_on(cs)
    end

    test "subject type and id come as a pair" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "subject_type" => "Contact"})
      assert %{subject_id: ["must be set together with subject type"]} = errors_on(cs)
    end

    test "visibility accepts known roles only, never disable" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["manager", "disable"]})
      assert %{visibility: ["has an invalid entry"]} = errors_on(cs)

      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["manager", "clerk"]})
      assert cs.valid?
    end

    test "an empty visibility list is rejected — public is nil" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => []})
      assert %{visibility: ["use nil for public"]} = errors_on(cs)
    end

    test "display_title falls back to the first body line" do
      assert Note.display_title(%Note{title: nil, body: "first line\nsecond"}) == "first line"
      assert Note.display_title(%Note{title: "T", body: "x"}) == "T"
    end
  end
end
