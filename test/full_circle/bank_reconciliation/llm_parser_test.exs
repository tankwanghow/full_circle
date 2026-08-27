defmodule FullCircle.BankReconciliation.LlmParserTest do
  use ExUnit.Case, async: true

  alias FullCircle.BankReconciliation.LlmParser

  describe "normalize_transaction/1" do
    test "accepts DD-MM-YYYY dates from bank statements" do
      assert %{
               statement_date: ~D[2026-05-01],
               description: "RPP INWARD",
               amount: amount
             } =
               LlmParser.normalize_transaction(%{
                 "statement_date" => "01-05-2026",
                 "description" => "RPP INWARD",
                 "cheque_no" => nil,
                 "amount" => 3390.00
               })

      assert Decimal.eq?(amount, Decimal.new("3390.00"))
    end

    test "accepts ISO dates" do
      assert %{statement_date: ~D[2026-05-01]} =
               LlmParser.normalize_transaction(%{
                 "statement_date" => "2026-05-01",
                 "description" => "test",
                 "amount" => 1
               })
    end
  end

  describe "stitch_cross_page_details/1" do
    # Shaped like the real Public Bank 2025-January statement: the last
    # transaction on page 2 (13/01 DEP-ECP 247269) keeps only its header line;
    # its detail lines print on page 3 after the "Balance B/F" row.
    @page_with_split_tail """
    TARIKH     URUS NIAGA                        DEBIT        KREDIT        BAKI
               DEP-CASH CDT 2517 012381                       930.00        32,326.55
    13/01      DEP-ECP 247269                                 97.69         32,424.24
               Balance C/F                                                  32,424.24

    Penyata ini dicetak melalui komputer.
    """

    @next_page_with_orphans """
    GOLDEN HUSBANDRY SDN BHD                     Nombor Akaun 3818548501
    TARIKH     URUS NIAGA                        DEBIT        KREDIT        BAKI

    13/01      Balance B/F                                                  32,424.24
               IMEPS20250113100002050336819 CIM
               UTMB - TNG DIGITAL SDN BHD TRUST A/C CIM
               XREF123456789A BEP25011203348 EP230
    15/01      DR-ECP 126360 2501142146540517    563.00                     31,861.24
               KUMPULAN WANG SIMPANAN PEKERJA
    """

    @next_page_without_orphans """
    GOLDEN HUSBANDRY SDN BHD                     Nombor Akaun 3818548501
    TARIKH     URUS NIAGA                        DEBIT        KREDIT        BAKI

    03/01      Balance B/F                                                  8,673.02
               TSFR FUND DR-ATM/EFT 612972       415.85                     8,257.17
               6488XXXXXX SAM KAH YING SAM KAH YING
    """

    test "moves orphan detail lines to the previous page, above its Balance C/F row" do
      [prev, next] =
        LlmParser.stitch_cross_page_details([@page_with_split_tail, @next_page_with_orphans])

      # Orphans now sit between the transaction header line and Balance C/F
      assert prev =~
               ~r/DEP-ECP 247269.*\n\s+IMEPS20250113100002050336819 CIM\n\s+UTMB - TNG DIGITAL SDN BHD TRUST A\/C CIM\n\s+XREF123456789A BEP25011203348 EP230\n\s+Balance C\/F/

      # Orphans removed from the next page; B/F row and real transactions remain
      refute next =~ "IMEPS20250113100002050336819"
      refute next =~ "UTMB - TNG DIGITAL"
      assert next =~ "Balance B/F"
      assert next =~ "DR-ECP 126360"
      assert next =~ "KUMPULAN WANG SIMPANAN PEKERJA"
    end

    test "leaves pages untouched when the line after Balance B/F is a normal transaction" do
      pages = [@page_with_split_tail, @next_page_without_orphans]
      assert LlmParser.stitch_cross_page_details(pages) == pages
    end

    test "leaves pages untouched when the next page has no B/F row" do
      pages = [@page_with_split_tail, "Some notes page\nwithout any transactions\n"]
      assert LlmParser.stitch_cross_page_details(pages) == pages
    end

    test "appends orphans at the end when the previous page has no C/F row" do
      prev_no_cf = """
      13/01      DEP-ECP 247269                                 97.69         32,424.24
      """

      [prev, _next] =
        LlmParser.stitch_cross_page_details([prev_no_cf, @next_page_with_orphans])

      assert prev =~
               ~r/DEP-ECP 247269.*\n.*\n?\s+IMEPS20250113100002050336819 CIM\n\s+UTMB - TNG DIGITAL/
    end

    test "stitches across every page boundary, not just the first" do
      pages = [
        @page_with_split_tail,
        @next_page_without_orphans <>
          "13/01      DEP-ECP 999999                97.69   32,424.24\n           Balance C/F                              32,424.24\n",
        @next_page_with_orphans
      ]

      [_p1, p2, p3] = LlmParser.stitch_cross_page_details(pages)

      assert p2 =~ ~r/DEP-ECP 999999.*\n\s+IMEPS20250113100002050336819 CIM/
      refute p3 =~ "IMEPS20250113100002050336819"
    end

    test "single page passes through unchanged" do
      assert LlmParser.stitch_cross_page_details([@page_with_split_tail]) ==
               [@page_with_split_tail]
    end
  end
end
