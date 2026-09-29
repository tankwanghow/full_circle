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
end
