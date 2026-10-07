defmodule FullCircle.LlmSettingsTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Sys

  setup do
    %{company: company_fixture(user_fixture(), %{})}
  end

  defp put(company, key, map) do
    {:ok, company} = Sys.update_company_settings(company, key, map)
    company
  end

  test "default profile is the shared llm setting over blanks", %{company: c} do
    assert Sys.llm_settings(c) == %{
             "llm-provider" => "none",
             "llm-endpoint" => "",
             "llm-model" => "",
             "llm-api-key" => ""
           }

    c = put(c, "llm", %{"llm-provider" => "claude", "llm-api-key" => "k1"})
    assert Sys.llm_settings(c)["llm-provider"] == "claude"
    assert Sys.llm_settings(c)["llm-api-key"] == "k1"
    assert Sys.llm_settings(c)["llm-model"] == ""
  end

  test "receipt profile: non-blank receipt fields win, blank ones fall back", %{company: c} do
    c =
      c
      |> put("llm", %{
        "llm-provider" => "claude",
        "llm-endpoint" => "",
        "llm-model" => "claude-sonnet-4-6",
        "llm-api-key" => "k1"
      })
      |> put("llm_receipt", %{
        "llm-provider" => "",
        "llm-endpoint" => "",
        "llm-model" => "claude-haiku-4-5-20251001",
        "llm-api-key" => ""
      })

    receipt = Sys.llm_settings(c, :receipt)
    assert receipt["llm-model"] == "claude-haiku-4-5-20251001"
    assert receipt["llm-provider"] == "claude"
    assert receipt["llm-api-key"] == "k1"
    assert Sys.llm_settings(c, :default)["llm-model"] == "claude-sonnet-4-6"
  end

  test "receipt profile with no receipt settings equals the default", %{company: c} do
    c = put(c, "llm", %{"llm-provider" => "gemini", "llm-api-key" => "g"})
    assert Sys.llm_settings(c, :receipt) == Sys.llm_settings(c)
  end

  test "receipt on another provider inherits nothing but its own fields", %{company: c} do
    c =
      c
      |> put("llm", %{
        "llm-provider" => "gemini",
        "llm-endpoint" => "https://gemini.example",
        "llm-model" => "gemini-2.5-flash",
        "llm-api-key" => "gemini-key"
      })
      |> put("llm_receipt", %{"llm-provider" => "claude", "llm-api-key" => ""})

    receipt = Sys.llm_settings(c, :receipt)
    assert receipt["llm-provider"] == "claude"
    assert receipt["llm-api-key"] == ""
    assert receipt["llm-model"] == ""
    assert receipt["llm-endpoint"] == ""
  end
end
