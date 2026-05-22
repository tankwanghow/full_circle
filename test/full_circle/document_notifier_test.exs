defmodule FullCircle.DocumentNotifierTest do
  use FullCircle.DataCase, async: true
  import Swoosh.TestAssertions

  alias FullCircle.DocumentNotifier

  test "deliver_document_link/4 sends an email containing the link" do
    company = %{name: "Acme Sdn Bhd", email: "acme@example.com"}
    url = "https://app.example.com/shared/Invoice/abc/print?token=xyz"

    assert {:ok, _} =
             DocumentNotifier.deliver_document_link(
               "customer@example.com",
               "Your Invoice from Acme Sdn Bhd",
               url,
               company
             )

    assert_email_sent(fn email ->
      assert {_, "customer@example.com"} = hd(email.to)
      assert email.subject == "Your Invoice from Acme Sdn Bhd"
      assert email.text_body =~ url
      assert email.text_body =~ "30 days"
    end)
  end
end
