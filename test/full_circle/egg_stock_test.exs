defmodule FullCircle.EggStockTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.EggStock
  alias FullCircle.EggStock.EggStockDay

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.BillingFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    contact = contact_fixture(company, admin)

    {:ok, _} =
      EggStock.save_grades(company.id, [
        %{"name" => "AA", "nickname" => "AA", "position" => 0, "delete" => "false"},
        %{"name" => "A", "nickname" => "A", "position" => 1, "delete" => "false"},
        %{"name" => "B", "nickname" => "B", "position" => 2, "delete" => "false"}
      ])

    %{admin: admin, company: company, contact: contact}
  end

  describe "weekly DOW books" do
    test "save and list sales lines by weekday", %{company: company, admin: admin, contact: contact} do
      params = [
        %{
          "id" => "",
          "contact_id" => contact.id,
          "contact_name" => contact.name,
          "quantities" => %{"AA" => "10", "A" => "20", "B" => "5"},
          "delete" => "false"
        }
      ]

      assert {:ok, lines} =
               EggStock.save_dow_lines(company.id, :sales, 1, params, company, admin)

      assert length(lines) == 1
      assert hd(lines).contact_id == contact.id
      assert EggStock.to_int(hd(lines).quantities["AA"]) == 10

      totals = EggStock.dow_totals(company.id, :sales, 1)
      assert totals["AA"] == 10
      assert totals["A"] == 20
      assert totals["B"] == 5

      # other weekday empty
      assert EggStock.dow_totals(company.id, :sales, 2)["AA"] == 0
    end

    test "save lines with named groups ordered by group_position", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      contact2 = contact_fixture(company, admin, %{"name" => "Second Contact #{System.unique_integer()}"})

      params = [
        %{
          "id" => "",
          "contact_id" => contact2.id,
          "contact_name" => contact2.name,
          "group_name" => "Afternoon",
          "group_position" => "1",
          "position" => "0",
          "quantities" => %{"AA" => "5"},
          "delete" => "false"
        },
        %{
          "id" => "",
          "contact_id" => contact.id,
          "contact_name" => contact.name,
          "group_name" => "Morning",
          "group_position" => "0",
          "position" => "0",
          "quantities" => %{"AA" => "9"},
          "delete" => "false"
        }
      ]

      assert {:ok, lines} =
               EggStock.save_dow_lines(company.id, :sales, 5, params, company, admin)

      assert length(lines) == 2
      assert Enum.map(lines, & &1.group_name) == ["Morning", "Afternoon"]
      assert hd(lines).contact_id == contact.id
    end

    test "replace semantics purge removed lines", %{company: company, admin: admin, contact: contact} do
      {:ok, [line]} =
        EggStock.save_dow_lines(
          company.id,
          :purchase,
          3,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"AA" => "7"},
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      assert {:ok, []} =
               EggStock.save_dow_lines(
                 company.id,
                 :purchase,
                 3,
                 [
                   %{
                     "id" => line.id,
                     "contact_id" => contact.id,
                     "contact_name" => contact.name,
                     "quantities" => %{"AA" => "7"},
                     "delete" => "true"
                   }
                 ],
                 company,
                 admin
               )
    end
  end

  describe "planned sales/purchases resolution" do
    test "falls back to DOW book when no day override", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      monday = ~D[2026-07-20]
      assert Date.day_of_week(monday) == 1

      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :sales,
          1,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"AA" => "15", "A" => "0", "B" => "0"},
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      rows = EggStock.planned_sales_for_date(company.id, monday)
      assert length(rows) == 1
      assert hd(rows).source == :book
      assert EggStock.planned_sales_totals(company.id, monday)["AA"] == 15
    end

    test "day override wins over weekly book", %{company: company, admin: admin, contact: contact} do
      monday = ~D[2026-07-20]

      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :sales,
          1,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"AA" => "100"},
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      {:ok, day} = EggStock.get_or_create_day(company.id, monday)

      {:ok, day} =
        EggStock.save_day(
          day,
          %{
            "egg_stock_day_details" => %{
              "0" => %{
                "section" => "planned_order",
                "contact_id" => contact.id,
                "contact_name" => contact.name,
                "quantities" => %{"AA" => "3"},
                "ignore" => "false"
              }
            }
          },
          company,
          admin
        )

      day = FullCircle.Repo.preload(day, [egg_stock_day_details: EggStock.__day_details_query__()], force: true)
      assert EggStock.day_has_planned_sales?(day)
      assert EggStock.planned_sales_totals(company.id, monday)["AA"] == 3
    end

    test "copy_dow_book_to_day and clear_day_planned_section", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      tuesday = ~D[2026-07-21]
      assert Date.day_of_week(tuesday) == 2

      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :purchase,
          2,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"B" => "40"},
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      {:ok, day} = EggStock.get_or_create_day(company.id, tuesday)
      assert {:ok, day} = EggStock.copy_dow_book_to_day(day, :purchase, company, admin)
      assert EggStock.day_has_planned_purchases?(day)
      assert EggStock.planned_purchases_totals(company.id, tuesday)["B"] == 40

      assert {:ok, day} = EggStock.clear_day_planned_section(day, :purchase, company, admin)
      refute EggStock.day_has_planned_purchases?(day)
      # still book
      assert EggStock.planned_purchases_totals(company.id, tuesday)["B"] == 40
    end
  end

  describe "hybrid 7-day forecast" do
    test "uses weekly book SO/PO and rolls closing", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      # Seed a closed day for opening + production avg base
      yesterday = Date.add(Date.utc_today(), -1)

      {:ok, day} = EggStock.get_or_create_day(company.id, yesterday)

      {:ok, _} =
        EggStock.save_day(
          day,
          %{
            "closing_bal" => %{"AA" => "100", "A" => "200", "B" => "50"},
            "expired" => %{},
            "ungraded_bal" => "0"
          },
          company,
          admin
        )

      today = Date.utc_today()
      dow = Date.day_of_week(today)

      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :sales,
          dow,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"AA" => "10", "A" => "0", "B" => "0"},
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      forecast = EggStock.compute_7day_forecast(company.id, today, 2)
      assert length(forecast) == 7

      first = hd(forecast)
      assert first.date == today
      assert first.sales["AA"] == 10
      # Opening = yesterday closing (100). Production avg from that day with no docs:
      # prod = sold+expired+closing-opening-purchased = 0+0+100-0-0 = 100
      # Est closing = 100 + 100 + 0 - 10 = 190
      assert first.closing["AA"] == 190
      assert first.purchases["AA"] == 0
    end
  end

  describe "stock day basics" do
    test "get_or_create_day and opening from previous closing", %{company: company, admin: admin} do
      d1 = ~D[2026-06-01]
      d2 = ~D[2026-06-02]

      {:ok, day1} = EggStock.get_or_create_day(company.id, d1)

      {:ok, _} =
        EggStock.save_day(
          day1,
          %{"closing_bal" => %{"AA" => "12", "A" => "0", "B" => "0"}},
          company,
          admin
        )

      assert EggStock.get_previous_closing_bal(company.id, d2)["AA"] in [12, "12"]
      assert %EggStockDay{} = EggStock.get_day(company.id, d1)
    end
  end

  describe "orphan documents become planned lines" do
    test "ensure_planned_lines_for_actuals adds missing contacts", %{contact: contact} do
      day = %FullCircle.EggStock.EggStockDay{
        egg_stock_day_details: []
      }

      actual_sales = [
        %{
          contact_id: contact.id,
          contact_name: contact.name,
          quantities: %{"AA" => 12, "A" => 3},
          doc_links: [{"Invoice", Ecto.UUID.generate()}]
        }
      ]

      {day, added?} = EggStock.ensure_planned_lines_for_actuals(day, actual_sales, [])
      assert added?
      assert length(day.egg_stock_day_details) == 1
      d = hd(day.egg_stock_day_details)
      assert d.section == "planned_order"
      assert d.contact_id == contact.id
      assert d.quantities["AA"] == 12
      # Mixed into normal groups (ungrouped when no prior lines)
      assert d.group_name == ""
    end

    test "does not duplicate existing planned contact", %{contact: contact} do
      day = %FullCircle.EggStock.EggStockDay{
        egg_stock_day_details: [
          %FullCircle.EggStock.EggStockDayDetail{
            section: "planned_order",
            contact_id: contact.id,
            contact_name: contact.name,
            quantities: %{"AA" => 1},
            group_name: "",
            group_position: 0
          }
        ]
      }

      actual_sales = [
        %{
          contact_id: contact.id,
          contact_name: contact.name,
          quantities: %{"AA" => 99},
          doc_links: [{"Invoice", Ecto.UUID.generate()}]
        }
      ]

      {day, added?} = EggStock.ensure_planned_lines_for_actuals(day, actual_sales, [])
      refute added?
      assert length(day.egg_stock_day_details) == 1
    end
  end

  describe "overlay actual quantities on planned lines" do
    test "replaces planned quantities when contact has actual documents", %{contact: contact} do
      planned = [
        %{
          contact_id: contact.id,
          contact_name: contact.name,
          quantities: %{"AA" => 10, "A" => 5},
          ignore: false,
          source: :day
        },
        %{
          contact_id: Ecto.UUID.generate(),
          contact_name: "Other",
          quantities: %{"AA" => 99},
          ignore: false,
          source: :day
        }
      ]

      actuals = [
        %{
          contact_id: contact.id,
          contact_name: contact.name,
          quantities: %{"AA" => 40, "A" => 20, "B" => 3},
          doc_links: [{"Invoice", Ecto.UUID.generate()}]
        }
      ]

      [synced, untouched] = EggStock.overlay_actual_quantities(planned, actuals)
      assert synced.quantities["AA"] == 40
      assert synced.quantities["A"] == 20
      assert synced.quantities["B"] == 3
      assert untouched.quantities["AA"] == 99
    end

    test "sync_day_details_from_actuals updates matching detail quantities", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      date = ~D[2026-06-10]
      {:ok, day} = EggStock.get_or_create_day(company.id, date)

      {:ok, day} =
        EggStock.save_day(
          day,
          %{
            "egg_stock_day_details" => %{
              "0" => %{
                "section" => "planned_order",
                "contact_id" => contact.id,
                "contact_name" => contact.name,
                "quantities" => %{"AA" => "10", "A" => "0", "B" => "0"}
              }
            }
          },
          company,
          admin
        )

      day =
        FullCircle.Repo.preload(day, [egg_stock_day_details: EggStock.__day_details_query__()],
          force: true
        )

      actual_sales = [
        %{
          contact_id: contact.id,
          contact_name: contact.name,
          quantities: %{"AA" => 55, "A" => 1, "B" => 0},
          doc_links: [{"Invoice", Ecto.UUID.generate()}]
        }
      ]

      {synced, changed?} = EggStock.sync_day_details_from_actuals(day, actual_sales, [])
      assert changed?
      detail = Enum.find(synced.egg_stock_day_details, &(&1.contact_id == contact.id))
      assert detail.quantities["AA"] == 55
      assert detail.quantities["A"] == 1
    end
  end
end
