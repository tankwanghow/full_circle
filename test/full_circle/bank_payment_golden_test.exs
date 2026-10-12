defmodule FullCircle.BankPaymentGoldenTest do
  use ExUnit.Case, async: true

  alias FullCircle.{BankPayment, FileSpec}
  alias FullCircle.BankPayment.Rows

  defp row(attrs) do
    Map.merge(
      %{
        "record_id" => "000000000001",
        "payment_no" => "PV-000001",
        "doc_date" => ~D[2026-10-10],
        "amount" => Decimal.new("1000.00"),
        "bank_code" => "MBBEMYKL",
        "account_no" => "112233374890",
        "account_name" => "Supplier",
        "contact_name" => "Supplier",
        "reg_no" => "",
        "email" => "",
        "emails" => "",
        "descriptions" => "",
        "advice" => [],
        "advice_text" => ""
      },
      attrs
    )
  end

  defp lines(text), do: String.split(text, "\r\n", trim: true)

  test "e-mails: first single address, all joined with ;" do
    assert Rows.emails("a@x.com, b@y.com; junk") == {"a@x.com", "a@x.com;b@y.com"}
    assert Rows.emails(nil) == {"", ""}
  end

  describe "RHB Reflex Bulk Pay" do
    setup do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")

      header = %{
        "corporate_id" => "123456",
        "corporate_name" => "FULL CIRCLE & CO SDN BHD",
        "our_account_no" => "21234500012345",
        "payment_date" => ~D[2026-10-15],
        "today" => ~D[2026-10-12],
        "company_name" => "Full Circle",
        "seq" => 1,
        "batch_no" => "20261012001"
      }

      %{spec: spec, header: header}
    end

    # RHB's published worked example: hash total 164632936.
    test "hash total matches RHB's worked example", %{spec: spec, header: header} do
      rows =
        ["112233374890", "112233464890", "112233464890", "112233464890", "112233185456"]
        |> Enum.with_index(1)
        |> Enum.map(fn {acct, i} ->
          row(%{"account_no" => acct, "record_id" => String.pad_leading("#{i}", 12, "0")})
        end)

      assert {:ok, text} = BankPayment.render_file(spec, rows, header)
      assert List.last(lines(text)) == "99,20261012001,5,5000.00,164632936,,,,,"
    end

    test "cents and amounts over RM1M", %{spec: spec, header: header} do
      rows = [
        row(%{"account_no" => "112233374890", "amount" => Decimal.new("1234567.89")}),
        row(%{
          "account_no" => "5000184560001",
          "amount" => Decimal.new("1000.50"),
          "record_id" => "000000000002"
        })
      ]

      assert {:ok, text} = BankPayment.render_file(spec, rows, header)
      assert List.last(lines(text)) == "99,20261012001,2,1235568.39,7452364105,,,,,"
    end

    test "header, quoted name with & → AND, e-mails, advice children, filename", %{
      spec: spec,
      header: header
    } do
      r =
        row(%{
          "account_name" => "Tan, Lee & Sons",
          "reg_no" => "REG001",
          "descriptions" => "Test payment",
          "emails" => "ah@example.com;b@example.com",
          "advice" => [
            %{
              "doc_no" => "INV-1",
              "doc_date" => ~D[2026-10-01],
              "amount" => Decimal.new("995.00")
            },
            %{"doc_no" => "", "doc_date" => ~D[2026-10-10], "amount" => Decimal.new("5.00")}
          ]
        })

      assert {:ok, text} = BankPayment.render_file(spec, [r], header)
      [h, d, a1, a2, _f] = lines(text)

      assert h ==
               Enum.join(
                 [
                   "00",
                   "01",
                   "123456",
                   "",
                   "FULL CIRCLE AND CO SDN BHD",
                   "21234500012345",
                   "15102026",
                   "20261012001",
                   "",
                   "A"
                 ] ++ List.duplicate("", 9),
                 ","
               )

      assert d ==
               Enum.join(
                 [
                   "10",
                   "10",
                   "000000000001",
                   "1000.00",
                   "MBBEMYKL",
                   "1",
                   ~s|"Tan, Lee AND Sons"|,
                   "112233374890",
                   "05",
                   "REG001",
                   "",
                   "",
                   "",
                   "PV-000001",
                   "Test payment"
                 ] ++
                   List.duplicate("", 12) ++
                   ["ah@example.com;b@example.com"] ++ List.duplicate("", 5),
                 ","
               )

      assert a1 == "30,01102026,995.00,INV-1,INV-1,,,,"
      assert a2 == "30,10102026,5.00,,PV-000001,,,,"
      assert FileSpec.filename(spec, header, 1) == "PAYMENT_123456_12102026_001.CSV"
    end
  end

  describe "PB enterprise ECP Payment" do
    setup do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("pbb_ecp_payment")

      header = %{
        "our_account_no" => "3999999999",
        "payment_date" => ~D[2026-10-15],
        "today" => ~D[2026-10-12],
        "company_name" => "Full Circle",
        "seq" => 1,
        "batch_no" => "20261012001"
      }

      %{spec: spec, header: header}
    end

    test "fixed widths, PBB vs IBG, cents, hash and e-mail advice lines", %{
      spec: spec,
      header: header
    } do
      pbb =
        row(%{
          "bank_code" => "PBBEMYKL",
          "account_no" => "3123456789",
          "amount" => Decimal.new("1200.50"),
          "advice_text" => "INV-9 01/10/2026 1200.50",
          "email" => "pé@x.com"
        })

      ibg = row(%{"record_id" => "000000000002", "amount" => Decimal.new("99.99")})

      assert {:ok, text} = BankPayment.render_file(spec, [pbb, ibg], header)
      [h, d1, d2, f] = lines(text)

      assert h == "H399999999920261015"
      assert byte_size(d1) == 781
      assert byte_size(d2) == 781
      assert String.slice(d1, 17, 3) == "PBB"
      assert String.slice(d2, 17, 3) == "IBG"
      assert String.slice(d1, 40, 11) == "PBBEMYKL   "
      assert String.slice(d1, 202, 16) == "0000000000120050"
      assert String.slice(d1, 581, 40) == String.pad_trailing("INV-9 01/10/2026 1200.50", 40)
      # total cents 130049 + first-4-digit sum (3123 + 1122) = 134294
      assert f == "F0000000002" <> "00000000000000130049" <> "00000000000000134294"
      assert FileSpec.filename(spec, header, 1) == "3999999999PM15102601.txt"
    end
  end
end
