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
    test "save and list sales lines by weekday", %{
      company: company,
      admin: admin,
      contact: contact
    } do
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

    test "save lines with separators ordered by list position", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      contact2 =
        contact_fixture(company, admin, %{"name" => "Second Contact #{System.unique_integer()}"})

      params = [
        %{
          "id" => "",
          "contact_id" => contact.id,
          "contact_name" => contact.name,
          "quantities" => %{"AA" => "9"},
          "delete" => "false"
        },
        %{
          "id" => "",
          "contact_id" => "",
          "contact_name" => "",
          "group_name" => "Morning batch",
          "is_separator" => "true",
          "quantities" => %{},
          "delete" => "false"
        },
        %{
          "id" => "",
          "contact_id" => contact2.id,
          "contact_name" => contact2.name,
          "quantities" => %{"AA" => "5"},
          "delete" => "false"
        }
      ]

      assert {:ok, lines} =
               EggStock.save_dow_lines(company.id, :sales, 5, params, company, admin)

      assert length(lines) == 3
      assert Enum.map(lines, & &1.position) == [0, 1, 2]
      assert Enum.at(lines, 0).contact_id == contact.id
      assert Enum.at(lines, 1).is_separator == true
      assert Enum.at(lines, 1).group_name == "Morning batch"
      assert Enum.at(lines, 2).contact_id == contact2.id

      # Separators do not contribute to totals
      totals = EggStock.dow_totals(company.id, :sales, 5)
      assert totals["AA"] == 14
    end

    test "replace semantics purge removed lines", %{
      company: company,
      admin: admin,
      contact: contact
    } do
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

    test "accepts ad-hoc contact name without contact_id", %{company: company, admin: admin} do
      params = [
        %{
          "id" => "",
          "contact_id" => "",
          "contact_name" => "CINDY",
          "quantities" => %{"AA" => "3", "A" => "0", "B" => "0"},
          "delete" => "false"
        }
      ]

      assert {:ok, [line]} =
               EggStock.save_dow_lines(company.id, :sales, 4, params, company, admin)

      assert is_nil(line.contact_id)
      assert line.contact_name == "CINDY"
      assert EggStock.to_int(line.quantities["AA"]) == 3

      reloaded = EggStock.list_dow_lines(company.id, :sales, 4)
      assert length(reloaded) == 1
      assert hd(reloaded).contact_name == "CINDY"
      assert is_nil(hd(reloaded).contact_id)
      assert EggStock.dow_totals(company.id, :sales, 4)["AA"] == 3
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

      day =
        FullCircle.Repo.preload(day, [egg_stock_day_details: EggStock.__day_details_query__()],
          force: true
        )

      assert EggStock.day_has_planned_sales?(day)
      assert EggStock.planned_sales_totals(company.id, monday, nil, monday)["AA"] == 3
    end

    test "book wins over day lines for dates after today", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      today = ~D[2026-07-20]
      future = ~D[2026-07-27]
      assert Date.day_of_week(future) == 1

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

      {:ok, day} = EggStock.get_or_create_day(company.id, future)

      {:ok, _} =
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

      rows = EggStock.planned_sales_for_date(company.id, future, today)
      assert Enum.map(rows, & &1.source) == [:book]
      assert EggStock.planned_sales_totals(company.id, future, nil, today)["AA"] == 100
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

    test "future rows follow the book even when the day has saved planned lines", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      today = ~D[2026-07-20]
      wednesday = ~D[2026-07-22]
      assert Date.day_of_week(wednesday) == 3

      {:ok, prev} = EggStock.get_or_create_day(company.id, Date.add(today, -1))

      {:ok, _} =
        EggStock.save_day(
          prev,
          %{"closing_bal" => %{"AA" => "100"}, "expired" => %{}, "ungraded_bal" => "0"},
          company,
          admin
        )

      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :sales,
          3,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"AA" => "50"},
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      {:ok, day} = EggStock.get_or_create_day(company.id, wednesday)

      {:ok, _} =
        EggStock.save_day(
          day,
          %{
            "egg_stock_day_details" => %{
              "0" => %{
                "section" => "planned_order",
                "contact_id" => contact.id,
                "contact_name" => contact.name,
                "quantities" => %{"AA" => "5"},
                "ignore" => "false"
              }
            }
          },
          company,
          admin
        )

      forecast = EggStock.compute_7day_forecast(company.id, today, 2, today)
      row = Enum.find(forecast, &(&1.date == wednesday))

      assert row.sales["AA"] == 50
    end
  end

  describe "stock day basics" do
    test "planned line accepts ad-hoc contact name without contact_id", %{
      company: company,
      admin: admin
    } do
      date = ~D[2026-06-10]
      {:ok, day} = EggStock.get_or_create_day(company.id, date)

      assert {:ok, day} =
               EggStock.save_day(
                 day,
                 %{
                   "egg_stock_day_details" => %{
                     "0" => %{
                       "section" => "planned_order",
                       "contact_id" => "",
                       "contact_name" => "CASH SALE",
                       "quantities" => %{"AA" => "5", "A" => "0", "B" => "0"},
                       "ignore" => "false",
                       "is_separator" => "false",
                       "position" => "0"
                     }
                   }
                 },
                 company,
                 admin
               )

      detail =
        day.egg_stock_day_details
        |> Enum.find(&(&1.section == "planned_order"))

      assert detail
      assert is_nil(detail.contact_id)
      assert detail.contact_name == "CASH SALE"

      reloaded = EggStock.get_day(company.id, date)
      d = Enum.find(reloaded.egg_stock_day_details, &(&1.section == "planned_order"))
      assert d.contact_name == "CASH SALE"
      assert is_nil(d.contact_id)
    end

    test "attach_contact_from_document updates ad-hoc planned line", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      date = ~D[2026-06-11]
      {:ok, day} = EggStock.get_or_create_day(company.id, date)

      assert {:ok, day} =
               EggStock.save_day(
                 day,
                 %{
                   "egg_stock_day_details" => %{
                     "0" => %{
                       "section" => "planned_order",
                       "contact_id" => "",
                       "contact_name" => "CINDY",
                       "quantities" => %{"AA" => "2", "A" => "0", "B" => "0"},
                       "ignore" => "false",
                       "is_separator" => "false",
                       "position" => "0"
                     }
                   }
                 },
                 company,
                 admin
               )

      detail = Enum.find(day.egg_stock_day_details, &(&1.section == "planned_order"))
      assert is_nil(detail.contact_id)

      assert {:ok, :updated} =
               EggStock.attach_contact_from_document(company, admin, %{
                 detail_id: detail.id,
                 load_date: date,
                 side: :sales,
                 original_name: "CINDY",
                 contact_id: contact.id,
                 contact_name: contact.name
               })

      reloaded = EggStock.get_day(company.id, date)
      d = Enum.find(reloaded.egg_stock_day_details, &(&1.id == detail.id))
      assert d.contact_id == contact.id
      assert d.contact_name == contact.name
    end

    test "sync_day_details_from_actuals links ad-hoc line by name", %{
      company: company,
      admin: admin,
      contact: contact
    } do
      date = ~D[2026-06-12]
      {:ok, day} = EggStock.get_or_create_day(company.id, date)

      assert {:ok, day} =
               EggStock.save_day(
                 day,
                 %{
                   "egg_stock_day_details" => %{
                     "0" => %{
                       "section" => "planned_order",
                       "contact_id" => "",
                       "contact_name" => contact.name,
                       "quantities" => %{"AA" => "1", "A" => "0", "B" => "0"},
                       "ignore" => "false",
                       "is_separator" => "false",
                       "position" => "0"
                     }
                   }
                 },
                 company,
                 admin
               )

      actuals = [
        %{
          contact_id: contact.id,
          contact_name: contact.name,
          quantities: %{"AA" => 9},
          doc_links: [{"Invoice", Ecto.UUID.generate()}]
        }
      ]

      {synced, changed?} = EggStock.sync_day_details_from_actuals(day, actuals, [])
      assert changed?
      d = Enum.find(synced.egg_stock_day_details, &(&1.section == "planned_order"))
      assert d.contact_id == contact.id
      assert EggStock.to_int(d.quantities["AA"]) == 9
    end

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

  describe "loading_list_groups/3 for the day board" do
    setup %{company: company, admin: admin, contact: contact} do
      date = ~D[2026-08-10]
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
                "quantities" => %{"AA" => "10"},
                "position" => "0",
                "is_separator" => "false"
              },
              "1" => %{
                "section" => "planned_order",
                "contact_name" => "",
                "group_name" => "Lorry 2",
                "position" => "1",
                "is_separator" => "true"
              },
              "2" => %{
                "section" => "planned_order",
                "contact_name" => "Ah Seng",
                "quantities" => %{"AA" => "5", "A" => "3"},
                "position" => "2",
                "is_separator" => "false"
              },
              "3" => %{
                "section" => "planned_order",
                "contact_name" => "Kedai Muar",
                "quantities" => %{"B" => "7"},
                "position" => "3",
                "is_separator" => "false"
              },
              "4" => %{
                "section" => "planned_purchase",
                "contact_name" => "Supplier X",
                "quantities" => %{"AA" => "99"},
                "position" => "4",
                "is_separator" => "false"
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

      by_name =
        day.egg_stock_day_details
        |> Enum.reject(& &1.is_separator)
        |> Map.new(&{&1.contact_name, &1})

      %{date: date, day: day, by_name: by_name}
    end

    test "groups selected rows under the separator above them", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      ids = [by_name["Ah Seng"].id, by_name["Kedai Muar"].id]

      assert [%{group_name: "Lorry 2", rows: rows}] =
               EggStock.loading_list_groups(company.id, {:day, date}, ids)

      assert Enum.map(rows, & &1.contact_name) == ["Ah Seng", "Kedai Muar"]
      assert Enum.at(rows, 0).quantities == %{"AA" => 5, "A" => 3}
    end

    test "rows before any separator land in an unnamed group", %{
      company: company,
      contact: contact,
      date: date,
      by_name: by_name
    } do
      ids = [by_name[contact.name].id, by_name["Kedai Muar"].id]

      assert [
               %{group_name: "", rows: [%{contact_name: first}]},
               %{group_name: "Lorry 2", rows: [%{contact_name: "Kedai Muar"}]}
             ] = EggStock.loading_list_groups(company.id, {:day, date}, ids)

      assert first == contact.name
    end

    test "groups with no selected row are dropped", %{
      company: company,
      contact: contact,
      date: date,
      by_name: by_name
    } do
      ids = [by_name[contact.name].id]

      assert [%{group_name: "", rows: [_]}] =
               EggStock.loading_list_groups(company.id, {:day, date}, ids)
    end

    test "rows print in board position order regardless of id order", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      ids = [by_name["Kedai Muar"].id, by_name["Ah Seng"].id]

      assert [%{rows: rows}] = EggStock.loading_list_groups(company.id, {:day, date}, ids)
      assert Enum.map(rows, & &1.contact_name) == ["Ah Seng", "Kedai Muar"]
    end

    test "ignores ids from the planned purchase section", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      ids = [by_name["Supplier X"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:day, date}, ids)
    end

    test "ignores ids that belong to another date", %{
      company: company,
      date: _date,
      by_name: by_name
    } do
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:day, ~D[2026-08-11]}, ids)
    end

    test "ignores ids that belong to another company", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      other_admin = user_fixture()
      other_company = company_fixture(other_admin, %{})
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(other_company.id, {:day, date}, ids)
      assert [_] = EggStock.loading_list_groups(company.id, {:day, date}, ids)
    end

    test "returns no groups for an empty selection", %{company: company, date: date} do
      assert [] == EggStock.loading_list_groups(company.id, {:day, date}, [])
    end
  end

  describe "loading_list_groups/3 for the weekly book" do
    setup %{company: company, admin: admin, contact: contact} do
      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :sales,
          3,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"AA" => "10"},
              "is_separator" => "false",
              "delete" => "false"
            },
            %{
              "id" => "",
              "contact_name" => "",
              "group_name" => "Lorry 2",
              "is_separator" => "true",
              "delete" => "false"
            },
            %{
              "id" => "",
              "contact_name" => "Ah Seng",
              "quantities" => %{"AA" => "5", "A" => "3"},
              "is_separator" => "false",
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :purchase,
          3,
          [
            %{
              "id" => "",
              "contact_name" => "Supplier X",
              "quantities" => %{"AA" => "99"},
              "is_separator" => "false",
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      sales = EggStock.list_dow_lines(company.id, :sales, 3)
      purchases = EggStock.list_dow_lines(company.id, :purchase, 3)
      by_name = Map.new(sales ++ purchases, &{&1.contact_name, &1})
      %{by_name: by_name}
    end

    test "groups selected weekly rows under their separator", %{
      company: company,
      by_name: by_name
    } do
      ids = [by_name["Ah Seng"].id]

      assert [%{group_name: "Lorry 2", rows: [row]}] =
               EggStock.loading_list_groups(company.id, {:dow, "sales", 3}, ids)

      assert row.contact_name == "Ah Seng"
      assert row.quantities == %{"AA" => 5, "A" => 3}
    end

    test "ignores ids from the purchase book", %{company: company, by_name: by_name} do
      ids = [by_name["Supplier X"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:dow, "sales", 3}, ids)
    end

    test "ignores ids from another weekday", %{company: company, by_name: by_name} do
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:dow, "sales", 4}, ids)
    end

    test "ignores ids from another company", %{company: _company, by_name: by_name} do
      other_admin = user_fixture()
      other_company = company_fixture(other_admin, %{})
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(other_company.id, {:dow, "sales", 3}, ids)
    end
  end

  describe "dow_date/2" do
    test "returns the same date when the weekday already matches" do
      monday = ~D[2026-08-10]
      assert Date.day_of_week(monday) == 1
      assert EggStock.dow_date(monday, 1) == monday
    end

    test "returns the next occurrence of a later weekday" do
      assert EggStock.dow_date(~D[2026-08-10], 3) == ~D[2026-08-12]
    end

    test "wraps to next week for an earlier weekday" do
      assert EggStock.dow_date(~D[2026-08-12], 1) == ~D[2026-08-17]
    end
  end
end
