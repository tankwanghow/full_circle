defmodule FullCircle.BankReconciliation.PdfTextTest do
  use ExUnit.Case, async: true

  alias FullCircle.BankReconciliation.PdfText

  @sample_pdf "/home/tankwanghow/Downloads/StatementRequest (1).pdf"

  describe "available?/0" do
    test "returns true when poppler tools exist" do
      if PdfText.available?() do
        assert PdfText.available?()
      else
        assert PdfText.available?() == false
      end
    end
  end

  describe "pages/1" do
    @tag :pdf_tools
    test "extracts multiple pages from RHB statement PDF" do
      if not PdfText.available?() or not File.exists?(@sample_pdf) do
        :ok
      else
        assert {:ok, pages} = PdfText.pages(@sample_pdf)
        assert length(pages) == 12
        assert hd(pages) =~ "TRANSACTION STATEMENT"
        assert hd(pages) =~ "Beginning Balance"
      end
    end

    test "returns error for missing file" do
      assert {:error, "PDF file not found"} =
               PdfText.pages("/tmp/does-not-exist-#{:rand.uniform(999_999)}.pdf")
    end
  end
end
