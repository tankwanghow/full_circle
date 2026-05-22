defmodule FullCircleWeb.SharedDocumentTest do
  use ExUnit.Case, async: true

  alias FullCircleWeb.SharedDocument

  @payload %{t: "Invoice", d: "doc-123", c: "company-1", u: "user-1"}

  describe "sign/4 and verify/1" do
    test "a freshly signed token verifies back to the payload" do
      token = SharedDocument.sign("Invoice", "doc-123", "company-1", "user-1")
      assert {:ok, payload} = SharedDocument.verify(token)
      assert payload == @payload
    end

    test "a tampered token is rejected" do
      token = SharedDocument.sign("Invoice", "doc-123", "company-1", "user-1")
      assert {:error, :invalid} = SharedDocument.verify(token <> "x")
    end

    test "a token older than 30 days is rejected as expired" do
      old =
        Phoenix.Token.sign(FullCircleWeb.Endpoint, "shared document", @payload,
          signed_at: System.system_time(:second) - 2_592_001
        )

      assert {:error, :expired} = SharedDocument.verify(old)
    end

    test "garbage input is rejected" do
      assert {:error, _} = SharedDocument.verify("not-a-token")
    end
  end
end
