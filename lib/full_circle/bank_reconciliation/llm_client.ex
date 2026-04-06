defmodule FullCircle.BankReconciliation.LlmClient do
  @moduledoc """
  Shared LLM HTTP client for bank reconciliation features.
  Supports Grok, Claude, Gemini, and Ollama providers.
  Returns {:ok, text, usage} or {:error, reason}.
  """

  @pricing %{
    "claude-sonnet-4-6" => %{input: 3.0, output: 15.0},
    "claude-haiku-4-5-20251001" => %{input: 0.80, output: 4.0},
    "claude-opus-4-6" => %{input: 15.0, output: 75.0},
    "gemini-2.5-flash" => %{input: 0.15, output: 0.60},
    "gemini-2.5-pro" => %{input: 1.25, output: 10.0},
    "gemini-2.0-flash" => %{input: 0.10, output: 0.40}
  }

  @providers %{
    "claude" => %{
      url: "https://api.anthropic.com/v1/messages",
      model: "claude-sonnet-4-6",
      format: :claude
    },
    "gemini" => %{
      url: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      model: "gemini-2.5-flash",
      format: :openai
    }
  }

  def active_model(settings) do
    provider = settings["llm-provider"] || "none"
    model = settings["llm-model"] || ""

    case {model, @providers[provider]} do
      {"", %{model: default}} -> default
      {"", _} -> provider
      {m, _} -> m
    end
  end

  def call(settings, system_prompt, user_prompt) do
    provider = settings["llm-provider"] || "none"

    case @providers[provider] do
      nil ->
        {:error, "LLM provider not configured."}

      config ->
        endpoint = non_blank(settings["llm-endpoint"], config.url)
        model = non_blank(settings["llm-model"], config.model)
        api_key = settings["llm-api-key"] || ""

        request(config.format, endpoint, model, api_key, system_prompt, user_prompt)
    end
  end

  def call_with_pdf(settings, system_prompt, user_prompt, pdf_base64) do
    provider = settings["llm-provider"] || "none"

    case @providers[provider] do
      nil ->
        {:error, "LLM provider not configured."}

      config ->
        endpoint = non_blank(settings["llm-endpoint"], config.url)
        model = non_blank(settings["llm-model"], config.model)
        api_key = settings["llm-api-key"] || ""

        request_with_pdf(config.format, endpoint, model, api_key, system_prompt, user_prompt, pdf_base64)
    end
  end

  # --- Claude native API ---

  defp request(:claude, url, model, api_key, system_prompt, user_prompt) do
    body =
      Jason.encode!(%{
        model: model,
        system: system_prompt,
        messages: [%{role: "user", content: user_prompt}],
        max_tokens: 65536
      })

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    with {:ok, resp} <- http_post(url, headers, body) do
      text = get_in(resp, ["content", Access.at(0), "text"]) || ""
      usage = resp["usage"] || %{}

      {:ok, text,
       build_usage(
         usage["input_tokens"] || 0,
         usage["output_tokens"] || 0,
         model,
         "claude"
       )}
    end
  end

  # --- OpenAI-compatible API (Grok, Gemini, Ollama) ---

  defp request(:openai, url, model, api_key, system_prompt, user_prompt) do
    body =
      Jason.encode!(%{
        model: model,
        messages: [
          %{role: "system", content: system_prompt},
          %{role: "user", content: user_prompt}
        ],
        max_tokens: 65536
      })

    headers =
      [{"content-type", "application/json"}] ++
        if(api_key != "" and api_key != nil,
          do: [{"authorization", "Bearer #{api_key}"}],
          else: []
        )

    with {:ok, resp} <- http_post(url, headers, body) do
      require Logger
      finish = get_in(resp, ["choices", Access.at(0), "finish_reason"])
      Logger.info("LLM finish_reason: #{inspect(finish)}")

      text = get_in(resp, ["choices", Access.at(0), "message", "content"]) || ""
      usage = resp["usage"] || %{}
      Logger.info("LLM usage: #{inspect(usage)}")

      {:ok, text,
       build_usage(
         usage["prompt_tokens"] || 0,
         usage["completion_tokens"] || 0,
         model,
         "openai"
       )}
    end
  end

  # --- Claude native API with PDF ---

  defp request_with_pdf(:claude, url, model, api_key, system_prompt, user_prompt, pdf_base64) do
    body =
      Jason.encode!(%{
        model: model,
        system: system_prompt,
        messages: [
          %{
            role: "user",
            content: [
              %{
                type: "document",
                source: %{type: "base64", media_type: "application/pdf", data: pdf_base64}
              },
              %{type: "text", text: user_prompt}
            ]
          }
        ],
        max_tokens: 65536
      })

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    with {:ok, resp} <- http_post(url, headers, body) do
      text = get_in(resp, ["content", Access.at(0), "text"]) || ""
      usage = resp["usage"] || %{}

      {:ok, text,
       build_usage(
         usage["input_tokens"] || 0,
         usage["output_tokens"] || 0,
         model,
         "claude"
       )}
    end
  end

  # --- OpenAI-compatible API with PDF (Gemini supports inline PDF) ---

  defp request_with_pdf(:openai, url, model, api_key, system_prompt, user_prompt, pdf_base64) do
    body =
      Jason.encode!(%{
        model: model,
        messages: [
          %{role: "system", content: system_prompt},
          %{
            role: "user",
            content: [
              %{
                type: "image_url",
                image_url: %{url: "data:application/pdf;base64,#{pdf_base64}"}
              },
              %{type: "text", text: user_prompt}
            ]
          }
        ],
        max_tokens: 65536
      })

    headers =
      [{"content-type", "application/json"}] ++
        if(api_key != "" and api_key != nil,
          do: [{"authorization", "Bearer #{api_key}"}],
          else: []
        )

    with {:ok, resp} <- http_post(url, headers, body) do
      require Logger
      finish = get_in(resp, ["choices", Access.at(0), "finish_reason"])
      Logger.info("LLM finish_reason: #{inspect(finish)}")

      text = get_in(resp, ["choices", Access.at(0), "message", "content"]) || ""
      usage = resp["usage"] || %{}
      Logger.info("LLM usage: #{inspect(usage)}")

      {:ok, text,
       build_usage(
         usage["prompt_tokens"] || 0,
         usage["completion_tokens"] || 0,
         model,
         "openai"
       )}
    end
  end

  # --- Usage & Cost ---

  defp build_usage(input, output, model, provider) do
    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output,
      model: model,
      provider: provider,
      cost_estimate: estimate_cost(model, input, output)
    }
  end

  defp estimate_cost(model, input_tokens, output_tokens) do
    case @pricing[model] do
      %{input: ip, output: op} ->
        Float.round(input_tokens / 1_000_000 * ip + output_tokens / 1_000_000 * op, 6)

      nil ->
        nil
    end
  end

  def format_usage(usage) do
    cost =
      if usage.cost_estimate,
        do: " | ~$#{:erlang.float_to_binary(usage.cost_estimate, decimals: 4)}",
        else: ""

    "#{usage.provider}/#{usage.model}: #{usage.input_tokens} in + #{usage.output_tokens} out = #{usage.total_tokens} tokens#{cost}"
  end

  # --- HTTP ---

  defp http_post(url, headers, body) do
    h = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    case :httpc.request(
           :post,
           {to_charlist(url), h, ~c"application/json", body},
           [{:timeout, 600_000}],
           []
         ) do
      {:ok, {{_, 200, _}, _, resp}} ->
        {:ok, Jason.decode!(to_string(resp))}

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, "API error #{status}: #{to_string(resp) |> String.slice(0, 300)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp non_blank("", default), do: default
  defp non_blank(nil, default), do: default
  defp non_blank(val, _default), do: val
end
