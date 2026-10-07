defmodule FullCircle.BankReconciliation.LlmClientTest do
  use ExUnit.Case, async: false

  alias FullCircle.BankReconciliation.LlmClient

  setup do
    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn url, headers, body, timeout ->
      send(test_pid, {:llm_request, url, headers, Jason.decode!(body), timeout})

      if String.contains?(url, "anthropic") do
        {:ok,
         %{
           "content" => [%{"text" => "ok"}],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
         }}
      else
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}],
           "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2}
         }}
      end
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
  end

  @claude %{
    "llm-provider" => "claude",
    "llm-api-key" => "k",
    "llm-endpoint" => "",
    "llm-model" => ""
  }
  @gemini %{
    "llm-provider" => "gemini",
    "llm-api-key" => "g",
    "llm-endpoint" => "",
    "llm-model" => ""
  }

  test "claude image: image block with media type, options applied" do
    assert {:ok, "ok", usage} =
             LlmClient.call_with_image(@claude, "sys", "read", "QUJD", "image/jpeg",
               timeout: 90_000,
               max_tokens: 4096
             )

    assert_received {:llm_request, _url, _h, body, 90_000}
    [%{"content" => [block, text]}] = body["messages"]

    assert block == %{
             "type" => "image",
             "source" => %{"type" => "base64", "media_type" => "image/jpeg", "data" => "QUJD"}
           }

    assert text == %{"type" => "text", "text" => "read"}
    assert body["max_tokens"] == 4096
    assert usage.total_tokens == 12
  end

  test "gemini image: data URI image_url" do
    assert {:ok, "ok", _} =
             LlmClient.call_with_image(@gemini, "sys", "read", "QUJD", "image/png")

    assert_received {:llm_request, _url, _h, body, 600_000}
    [_sys, %{"content" => [block, _]}] = body["messages"]

    assert block == %{
             "type" => "image_url",
             "image_url" => %{"url" => "data:image/png;base64,QUJD"}
           }
  end

  test "pdf keeps the document block and the old defaults" do
    assert {:ok, "ok", _} = LlmClient.call_with_pdf(@claude, "sys", "read", "UERG")
    assert_received {:llm_request, _url, _h, body, 600_000}
    [%{"content" => [block, _]}] = body["messages"]
    assert block["type"] == "document"
    assert block["source"]["media_type"] == "application/pdf"
    assert body["max_tokens"] == 65_536
  end

  test "no provider: error, no request" do
    assert {:error, _} =
             LlmClient.call_with_image(%{"llm-provider" => "none"}, "s", "u", "x", "image/jpeg")

    refute_received {:llm_request, _, _, _, _}
  end
end
