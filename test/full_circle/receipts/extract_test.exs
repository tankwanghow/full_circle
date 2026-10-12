defmodule FullCircle.Receipts.ExtractTest do
  use ExUnit.Case, async: false

  alias FullCircle.Receipts.{Extract, Extracted}

  @today ~D[2026-10-07]
  @settings %{
    "llm-provider" => "claude",
    "llm-api-key" => "k",
    "llm-endpoint" => "",
    "llm-model" => ""
  }

  @good %{
    "recognized" => true,
    "summary" => "Hardware receipt from Kedai Ali, RM 58.32",
    "supplier" => %{
      "name" => "Kedai Ali Hardware",
      "tin" => "C2345678901",
      "brn" => "201901012345",
      "sst_no" => nil
    },
    "doc_no" => "A12345",
    "date" => "2026-10-03",
    "due_date" => nil,
    "lines" => [
      %{
        "description" => "PVC PIPE 2\"",
        "quantity" => 4,
        "unit_price" => 12.5,
        "discount" => 0,
        "tax_rate_percent" => nil,
        "amount" => 50.0
      },
      %{
        "description" => "GLUE 500ML",
        "quantity" => 1,
        "unit_price" => "RM 4.00",
        "discount" => nil,
        "tax_rate_percent" => nil,
        "amount" => "4.00"
      }
    ],
    "subtotal" => 54.0,
    "tax_total" => 4.32,
    "rounding" => 0,
    "total" => "RM 58.32",
    "payment_method" => "cash",
    "e_invoice_uuid" => nil
  }

  defp stub(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn _url, _h, body, timeout ->
      send(test_pid, {:llm_called, Jason.decode!(body), timeout})
      text = Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)

      {:ok,
       %{
         "content" => [%{"text" => text}],
         "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
       }}
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
  end

  defp tmp(ext, bytes) do
    path = Path.join(System.tmp_dir!(), "rcpt#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, bytes)
    path
  end

  describe "parse/2" do
    test "reads header, lines, totals; strips RM and commas" do
      ex = Extract.parse(@good, @today)

      assert %Extracted{
               recognized: true,
               supplier_name: "Kedai Ali Hardware",
               supplier_tin: "C2345678901"
             } = ex

      assert ex.doc_no == "A12345"
      assert ex.date == ~D[2026-10-03]
      assert ex.payment_method == "cash"
      assert Decimal.eq?(ex.total, Decimal.new("58.32"))
      assert Decimal.eq?(ex.tax_total, Decimal.new("4.32"))
      assert [pipe, glue] = ex.lines
      assert pipe.descriptions == "PVC PIPE 2\""
      assert Decimal.eq?(pipe.quantity, 4)
      assert Decimal.eq?(glue.unit_price, Decimal.new("4.00"))
      assert Decimal.eq?(glue.discount, 0)
      assert ex.warnings == []
    end

    test "DD/MM/YYYY date and 1,234.50 amounts" do
      ex =
        Extract.parse(
          %{@good | "date" => "03/10/2026", "total" => "1,234.50", "lines" => []},
          @today
        )

      assert ex.date == ~D[2026-10-03]
      assert Decimal.eq?(ex.total, Decimal.new("1234.50"))
    end

    test "lines that do not add up to the total warn" do
      ex = Extract.parse(%{@good | "total" => 70}, @today)
      assert Enum.any?(ex.warnings, &(&1 =~ "don't add up"))
    end

    test "tax-inclusive line amounts do not warn" do
      ex = Extract.parse(%{@good | "total" => 54, "rounding" => 0}, @today)
      refute Enum.any?(ex.warnings, &(&1 =~ "don't add up"))
    end

    test "future and very old dates warn" do
      assert Enum.any?(
               Extract.parse(%{@good | "date" => "2026-12-01"}, @today).warnings,
               &(&1 =~ "future")
             )

      assert Enum.any?(
               Extract.parse(%{@good | "date" => "2025-01-01"}, @today).warnings,
               &(&1 =~ "year old")
             )
    end

    test "an unreadable value becomes nil with a warning" do
      ex = Extract.parse(%{@good | "date" => "sometime"}, @today)
      assert ex.date == nil
      assert Enum.any?(ex.warnings, &(&1 =~ "date"))
    end

    test "total but no lines: one line for the net of tax and rounding" do
      ex = Extract.parse(%{@good | "lines" => [], "rounding" => -0.02, "total" => 58.30}, @today)
      [line] = ex.lines
      assert line.descriptions == "Kedai Ali Hardware"
      assert Decimal.eq?(line.unit_price, Decimal.new("54.00"))
    end

    test "negative total warns as a refund or credit note" do
      ex = Extract.parse(%{@good | "lines" => [], "tax_total" => 0, "total" => -20}, @today)
      assert Enum.any?(ex.warnings, &(&1 =~ "refund"))
    end

    test "recognized false keeps only the summary" do
      ex =
        Extract.parse(
          %{"recognized" => false, "summary" => "Photo of a cheque from Maybank"},
          @today
        )

      assert %Extracted{
               recognized: false,
               summary: "Photo of a cheque from Maybank",
               lines: [],
               total: nil
             } = ex

      assert Enum.any?(ex.warnings, &(&1 =~ "Not recognised"))
    end

    test "no total and no lines counts as not recognised" do
      ex =
        Extract.parse(
          %{"recognized" => true, "summary" => "Blurry shot", "lines" => [], "total" => nil},
          @today
        )

      refute ex.recognized
      assert ex.summary == "Blurry shot"
    end

    test "summary is cut at 200 characters" do
      ex =
        Extract.parse(%{"recognized" => false, "summary" => String.duplicate("x", 300)}, @today)

      assert String.length(ex.summary) == 200
    end
  end

  describe "decode_json/1" do
    test "plain, fenced and chatty replies" do
      assert {:ok, %{"a" => 1}} = Extract.decode_json(~s({"a": 1}))
      assert {:ok, %{"a" => 1}} = Extract.decode_json("```json\n{\"a\": 1}\n```")
      assert {:ok, %{"a" => 1}} = Extract.decode_json("Here it is: {\"a\": 1} hope it helps")
      assert :error = Extract.decode_json("sorry, I cannot")
    end
  end

  describe "parse_documents/2" do
    test "one entry per document" do
      second = Map.merge(@good, %{"doc_no" => "B-2", "supplier" => %{"name" => "Shell"}})
      docs = Extract.parse_documents(%{"documents" => [@good, second]}, @today)

      assert [%Extracted{doc_no: "A12345"}, %Extracted{doc_no: "B-2", supplier_name: "Shell"}] =
               docs
    end

    test "today's single-object reply is one document" do
      assert [%Extracted{recognized: true, doc_no: "A12345"}] =
               Extract.parse_documents(@good, @today)
    end

    test "an empty list is one unrecognised document" do
      assert [%Extracted{recognized: false, summary: "Blank page"}] =
               Extract.parse_documents(%{"documents" => [], "summary" => "Blank page"}, @today)
    end

    test "kind: the fixed label, case-insensitive; unknown is nil" do
      [fuel, toll, odd, none] =
        Extract.parse_documents(
          %{
            "documents" => [
              Map.put(@good, "kind", "fuel"),
              Map.put(@good, "kind", " TOLL "),
              Map.put(@good, "kind", "petrol"),
              @good
            ]
          },
          @today
        )

      assert {fuel.kind, toll.kind, odd.kind, none.kind} == {"Fuel", "Toll", nil, nil}
    end

    test "entries that are not objects are skipped" do
      assert [%Extracted{doc_no: "A12345"}] =
               Extract.parse_documents(%{"documents" => ["junk", 3, nil, @good]}, @today)

      assert [%Extracted{recognized: false}] =
               Extract.parse_documents(%{"documents" => ["junk"]}, @today)
    end
  end

  describe "run/4" do
    test "image: one call with the 180 s timeout and 32k tokens, a list back" do
      stub([Jason.encode!(%{"documents" => [@good, @good]})])
      path = tmp(".jpg", <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>)

      assert {:ok, [%Extracted{recognized: true}, %Extracted{}], usage} =
               Extract.run(path, "image/jpeg", @settings, today: @today)

      assert usage.total_tokens == 150
      assert_received {:llm_called, body, 180_000}
      assert body["max_tokens"] == 32_768
      [%{"content" => [%{"type" => "image"}, _]}] = body["messages"]
      assert body["system"] =~ "documents"
    end

    test "pdf goes as a document" do
      stub([Jason.encode!(@good)])
      path = tmp(".pdf", "%PDF-1.4 x")
      assert {:ok, _, _} = Extract.run(path, "application/pdf", @settings, today: @today)
      assert_received {:llm_called, body, _}
      [%{"content" => [%{"type" => "document"}, _]}] = body["messages"]
    end

    test "bad JSON retries once asking for JSON only" do
      stub(["I think this is a receipt", Jason.encode!(@good)])
      path = tmp(".jpg", <<0xFF, 0xD8, 0xFF>>)

      assert {:ok, [%Extracted{recognized: true}], _} =
               Extract.run(path, "image/jpeg", @settings, today: @today)

      assert_received {:llm_called, _, _}
      assert_received {:llm_called, second, _}
      [%{"content" => [_, %{"text" => text}]}] = second["messages"]
      assert text =~ "JSON object only"
    end

    test "bad JSON twice is an error" do
      stub(["nope", "still nope"])
      path = tmp(".jpg", <<0xFF, 0xD8, 0xFF>>)
      assert {:error, msg} = Extract.run(path, "image/jpeg", @settings, today: @today)
      assert msg =~ "could not be read"
    end

    test "a 4 MB photo is refused: its base64 exceeds the 5 MB image limit" do
      stub([])
      path = tmp(".png", :binary.copy(<<0>>, 4 * 1024 * 1024))
      assert {:error, msg} = Extract.run(path, "image/png", @settings, today: @today)
      assert msg =~ "too large"
      refute_received {:llm_called, _, _}
    end

    test "photo over 5 MB is refused before any call" do
      stub([])
      path = tmp(".jpg", :binary.copy(<<0>>, 5 * 1024 * 1024 + 1))
      assert {:error, msg} = Extract.run(path, "image/jpeg", @settings, today: @today)
      assert msg =~ "too large"
      refute_received {:llm_called, _, _}
    end

    test "unsupported type is refused" do
      stub([])
      assert {:error, msg} = Extract.run(tmp(".mp4", "x"), "video/mp4", @settings, today: @today)
      assert msg =~ "photos and PDFs"
    end
  end
end
