defmodule FullCircle.UserQueriesAuthTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures

  setup do
    billing_setup()
  end

  # Saved queries can read any column, including supplier bank details.
  describe "query authorization" do
    test_authorise_to(:create_query, ["admin", "manager"])
    test_authorise_to(:update_query, ["admin", "manager"])
    test_authorise_to(:delete_query, ["admin", "manager"])
    test_authorise_to(:execute_query, ["admin", "manager"])
  end
end
