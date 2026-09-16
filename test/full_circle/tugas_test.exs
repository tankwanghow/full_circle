defmodule FullCircle.TugasTest do
  use FullCircle.DataCase

  alias FullCircle.Tugas

  import FullCircle.BillingFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  # --- AUTHORIZATION (allow-lists; `tasker` is deliberately not a role) ---

  describe "tugas authorization" do
    test_authorise_to(:view_tugas, [
      "admin",
      "manager",
      "supervisor",
      "clerk",
      "cashier",
      "auditor"
    ])

    test_authorise_to(:create_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:update_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])

    test_authorise_to(:create_duty_event, ["admin", "manager", "supervisor", "clerk", "cashier"])

    test_authorise_to(:create_duty_event_document, [
      "admin",
      "manager",
      "supervisor",
      "clerk",
      "cashier"
    ])

    test_authorise_to(:complete_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:skip_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])

    test_authorise_to(:link_duty_document, [
      "admin",
      "manager",
      "supervisor",
      "clerk",
      "cashier"
    ])

    test_authorise_to(:end_duty_series, ["admin", "manager", "supervisor"])
    test_authorise_to(:unlink_duty_document, ["admin", "manager", "supervisor"])
    test_authorise_to(:correct_others_duty_event, ["admin", "manager", "supervisor"])
    test_authorise_to(:delete_others_duty_event, ["admin", "manager", "supervisor"])
  end

  describe "create_duty/3" do
    test "creates an active one-off duty whose series is itself", %{
      admin: admin,
      company: company
    } do
      assert {:ok, duty} =
               Tugas.create_duty(
                 %{"title" => "Pay the electricity bill", "due_date" => "2026-09-30"},
                 company,
                 admin
               )

      assert duty.title == "Pay the electricity bill"
      assert duty.status == "active"
      assert duty.company_id == company.id
      assert {:ok, _} = Ecto.UUID.dump(duty.series_id)
      assert is_nil(duty.recur_unit)
      assert is_nil(duty.series_ended_at)
    end

    test "requires a title", %{admin: admin, company: company} do
      assert {:error, :create_duty, %Ecto.Changeset{} = cs, _} =
               Tugas.create_duty(%{"title" => ""}, company, admin)

      assert "can't be blank" in errors_on(cs).title
    end
  end

  describe "update_duty/4" do
    test "updates title and due date", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Old"}, company, admin)

      assert {:ok, duty} =
               Tugas.update_duty(
                 duty,
                 %{"title" => "New", "due_date" => "2026-10-05"},
                 company,
                 admin
               )

      assert duty.title == "New"
      assert duty.due_date == ~D[2026-10-05]
    end

    test "cannot be used to move the duty out of active", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Old"}, company, admin)

      assert {:ok, duty} = Tugas.update_duty(duty, %{"status" => "done"}, company, admin)
      assert duty.status == "active"
    end
  end

  describe "add_progress/4" do
    test "appends a progress event carrying the author and note", %{
      admin: admin,
      company: company
    } do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Chase the supplier"}, company, admin)

      assert {:ok, event} =
               Tugas.add_progress(duty, %{"note" => "called, no answer"}, company, admin)

      assert event.action == "progress"
      assert event.note == "called, no answer"
      assert event.user_id == admin.id
      assert event.company_id == company.id
      assert event.duty_id == duty.id
    end

    test "leaves the duty active", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Chase"}, company, admin)
      {:ok, _} = Tugas.add_progress(duty, %{"note" => "ping"}, company, admin)

      assert Tugas.get_duty!(duty.id, company, admin).status == "active"
    end

    test "refuses a duty that is already closed", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Chase"}, company, admin)

      {:ok, duty} =
        duty |> Ecto.Changeset.change(status: "done") |> Repo.update()

      assert {:error, :not_live} = Tugas.add_progress(duty, %{"note" => "late"}, company, admin)
    end
  end

  defp recurring_duty(company, admin, attrs \\ %{}) do
    {:ok, duty} =
      Tugas.create_duty(
        Map.merge(
          %{
            "title" => "Pay rent",
            "due_date" => "2026-09-30",
            "recur_unit" => "month",
            "recur_every" => 1
          },
          attrs
        ),
        company,
        admin
      )

    duty
  end

  describe "recurrence validation" do
    test "a recurring duty needs a due date to advance from", %{admin: admin, company: company} do
      assert {:error, :create_duty, cs, _} =
               Tugas.create_duty(
                 %{"title" => "Pay rent", "recur_unit" => "month", "recur_every" => 1},
                 company,
                 admin
               )

      assert "can't be blank" in errors_on(cs).due_date
    end

    test "recur_every without a unit is rejected", %{admin: admin, company: company} do
      assert {:error, :create_duty, cs, _} =
               Tugas.create_duty(%{"title" => "x", "recur_every" => 2}, company, admin)

      assert "needs a recur unit" in errors_on(cs).recur_every
    end
  end

  describe "complete_duty/4" do
    test "closes the duty and records a done event", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "One off"}, company, admin)

      assert {:ok, %{duty: closed, next_duty: nil}} =
               Tugas.complete_duty(duty.id, %{"note" => "paid"}, company, admin)

      assert closed.status == "done"

      assert [%{action: "done", note: "paid", user_id: author}] =
               Tugas.list_duty_events(duty.id, company, admin)

      assert author == admin.id
    end

    test "spawns the next cycle of a recurring duty in the same series", %{
      admin: admin,
      company: company
    } do
      duty = recurring_duty(company, admin)

      assert {:ok, %{duty: closed, next_duty: next}} =
               Tugas.complete_duty(duty.id, %{}, company, admin)

      assert closed.status == "done"
      assert next.status == "active"
      assert next.series_id == duty.series_id
      assert next.title == duty.title
      assert next.recur_unit == "month"
      assert next.recur_every == 1
      # 30 Sep + 1 month
      assert next.due_date == ~D[2026-10-30]
    end

    test "month recurrence clamps instead of rolling into the next month", %{
      admin: admin,
      company: company
    } do
      duty = recurring_duty(company, admin, %{"due_date" => "2026-01-31"})

      assert {:ok, %{next_duty: next}} = Tugas.complete_duty(duty.id, %{}, company, admin)
      assert next.due_date == ~D[2026-02-28]
    end

    test "a closed duty cannot be closed again", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "One off"}, company, admin)
      assert {:ok, _} = Tugas.complete_duty(duty.id, %{}, company, admin)
      assert {:error, :not_live} = Tugas.complete_duty(duty.id, %{}, company, admin)
    end

    test "a duty from another company is not closeable", %{admin: admin, company: company} do
      %{admin: other_admin, company: other_company} = billing_setup()
      {:ok, duty} = Tugas.create_duty(%{"title" => "Theirs"}, other_company, other_admin)

      assert {:error, :not_live} = Tugas.complete_duty(duty.id, %{}, company, admin)
    end
  end

  describe "skip_duty/4" do
    test "marks the cycle skipped and still spawns the next one", %{
      admin: admin,
      company: company
    } do
      duty = recurring_duty(company, admin)

      assert {:ok, %{duty: closed, next_duty: next}} =
               Tugas.skip_duty(duty.id, %{"note" => "office shut"}, company, admin)

      assert closed.status == "skipped"
      assert next.status == "active"
      assert next.due_date == ~D[2026-10-30]

      assert [%{action: "skip", note: "office shut"}] =
               Tugas.list_duty_events(duty.id, company, admin)
    end
  end

  describe "end_series/3" do
    test "stamps the series and records an end_series event", %{admin: admin, company: company} do
      duty = recurring_duty(company, admin)

      assert {:ok, %{duty: ended}} = Tugas.end_series(duty, company, admin)
      assert ended.series_ended_at
      assert ended.status == "active"

      assert [%{action: "end_series"}] = Tugas.list_duty_events(duty.id, company, admin)
    end

    test "an ended series spawns no further cycle when the live one is closed", %{
      admin: admin,
      company: company
    } do
      duty = recurring_duty(company, admin)
      {:ok, _} = Tugas.end_series(duty, company, admin)

      assert {:ok, %{duty: closed, next_duty: nil}} =
               Tugas.complete_duty(duty.id, %{}, company, admin)

      assert closed.status == "done"
    end

    test "stamps every cycle of the series, not just the live one", %{
      admin: admin,
      company: company
    } do
      duty = recurring_duty(company, admin)
      {:ok, %{next_duty: next}} = Tugas.complete_duty(duty.id, %{}, company, admin)
      {:ok, _} = Tugas.end_series(next, company, admin)

      assert Tugas.get_duty!(duty.id, company, admin).series_ended_at
    end
  end

  describe "one live cycle per series" do
    test "the database refuses a second active duty in the same series", %{
      admin: admin,
      company: company
    } do
      duty = recurring_duty(company, admin)

      assert {:error, cs} =
               %FullCircle.Tugas.Duty{}
               |> FullCircle.Tugas.Duty.changeset(%{
                 "title" => "Sneaky second live cycle",
                 "series_id" => duty.series_id,
                 "status" => "active",
                 "company_id" => company.id
               })
               |> Repo.insert()

      assert "series already has a live cycle" in errors_on(cs).series_id
    end
  end

  describe "document_types/0" do
    test "only Payment is linkable for now" do
      assert Tugas.document_types() == ["Payment"]
    end
  end

  describe "link_document/4" do
    test "links a payment and records a linked event", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Pay the rent"}, company, admin)
      doc_id = Ecto.UUID.generate()

      assert {:ok, link} =
               Tugas.link_document(
                 duty,
                 %{"doc_type" => "Payment", "doc_id" => doc_id, "doc_no" => "PV-000001"},
                 company,
                 admin
               )

      assert link.doc_type == "Payment"
      assert link.doc_id == doc_id
      assert link.doc_no == "PV-000001"
      assert link.user_id == admin.id
      assert link.company_id == company.id

      assert [%{action: "linked", note: "Payment PV-000001"}] =
               Tugas.list_duty_events(duty.id, company, admin)
    end

    test "one duty can carry many documents", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Settle the month"}, company, admin)

      for no <- ~w(PV-000001 PV-000002 PV-000003) do
        assert {:ok, _} =
                 Tugas.link_document(
                   duty,
                   %{"doc_type" => "Payment", "doc_id" => Ecto.UUID.generate(), "doc_no" => no},
                   company,
                   admin
                 )
      end

      assert length(Tugas.list_duty_documents(duty.id, company, admin)) == 3
    end

    test "rejects a doc_type that is not whitelisted", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Nope"}, company, admin)

      assert {:error, cs} =
               Tugas.link_document(
                 duty,
                 %{"doc_type" => "Invoice", "doc_id" => Ecto.UUID.generate()},
                 company,
                 admin
               )

      assert "is invalid" in errors_on(cs).doc_type
    end

    test "the same document cannot be linked to the same duty twice", %{
      admin: admin,
      company: company
    } do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Dup"}, company, admin)
      attrs = %{"doc_type" => "Payment", "doc_id" => Ecto.UUID.generate(), "doc_no" => "PV-1"}

      assert {:ok, _} = Tugas.link_document(duty, attrs, company, admin)
      assert {:error, cs} = Tugas.link_document(duty, attrs, company, admin)
      assert "already linked to this duty" in errors_on(cs).doc_id
    end
  end

  describe "unlink_document/3" do
    test "removes the link and records an unlinked event", %{admin: admin, company: company} do
      {:ok, duty} = Tugas.create_duty(%{"title" => "Undo me"}, company, admin)

      {:ok, link} =
        Tugas.link_document(
          duty,
          %{"doc_type" => "Payment", "doc_id" => Ecto.UUID.generate(), "doc_no" => "PV-9"},
          company,
          admin
        )

      assert {:ok, _} = Tugas.unlink_document(link, company, admin)
      assert Tugas.list_duty_documents(duty.id, company, admin) == []

      assert [%{action: "linked"}, %{action: "unlinked", note: "Payment PV-9"}] =
               Tugas.list_duty_events(duty.id, company, admin)
    end

    test "a clerk may link but not unlink", %{admin: admin, company: company} do
      clerk = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)

      {:ok, duty} = Tugas.create_duty(%{"title" => "Clerk duty"}, company, clerk)

      {:ok, link} =
        Tugas.link_document(
          duty,
          %{"doc_type" => "Payment", "doc_id" => Ecto.UUID.generate(), "doc_no" => "PV-7"},
          company,
          clerk
        )

      assert :not_authorise = Tugas.unlink_document(link, company, clerk)
    end
  end

  describe "search_duties/4" do
    test "finds duties by title", %{admin: admin, company: company} do
      {:ok, _} = Tugas.create_duty(%{"title" => "Renew the road tax"}, company, admin)
      {:ok, _} = Tugas.create_duty(%{"title" => "File the SST return"}, company, admin)

      assert [%{title: "Renew the road tax"}] = Tugas.search_duties("road", company, admin)
    end

    test "treats % in the search terms as a literal, not a wildcard", %{
      admin: admin,
      company: company
    } do
      {:ok, _} = Tugas.create_duty(%{"title" => "100% collected"}, company, admin)
      {:ok, _} = Tugas.create_duty(%{"title" => "100 boxes collected"}, company, admin)

      assert [%{title: "100% collected"}] = Tugas.search_duties("100%", company, admin)
    end

    test "treats _ in the search terms as a literal, not a wildcard", %{
      admin: admin,
      company: company
    } do
      {:ok, _} = Tugas.create_duty(%{"title" => "job_1 handover"}, company, admin)
      {:ok, _} = Tugas.create_duty(%{"title" => "jobX1 handover"}, company, admin)

      assert [%{title: "job_1 handover"}] = Tugas.search_duties("job_1", company, admin)
    end

    test "does not leak duties from another company", %{admin: admin, company: company} do
      %{admin: other_admin, company: other_company} = billing_setup()
      {:ok, _} = Tugas.create_duty(%{"title" => "Secret road tax"}, other_company, other_admin)

      assert Tugas.search_duties("road", company, admin) == []
    end
  end

  # --- EVIDENCE -------------------------------------------------------------

  @png_magic <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg_magic <<0xFF, 0xD8, 0xFF, 0xE0>>
  @webp_magic "RIFF" <> <<0, 0, 0, 0>> <> "WEBP"
  @pdf_magic "%PDF-1.7\n"

  defp tmp_upload(bytes, name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "tugas_src_#{System.unique_integer([:positive])}_#{name}"
      )

    File.write!(path, bytes)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    %{path: path, file_name: name}
  end

  defp live_event(company, admin) do
    {:ok, duty} = Tugas.create_duty(%{"title" => "Evidence duty"}, company, admin)
    {:ok, event} = Tugas.add_progress(duty, %{"note" => "see attached"}, company, admin)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(Path.join(System.tmp_dir!(), company.id)) end)
    event
  end

  describe "attach_evidence/4" do
    test "derives the content type from the bytes, not from the client", %{
      admin: admin,
      company: company
    } do
      event = live_event(company, admin)

      # The name and anything a client might claim say PDF; the bytes say PNG.
      upload = tmp_upload(@png_magic <> "rest of the image", "receipt.pdf")

      assert {:ok, doc} = Tugas.attach_evidence(event, upload, company, admin)
      assert doc.content_type == "image/png"
      assert doc.file_name == "receipt.pdf"
      assert doc.duty_event_id == event.id
      assert doc.company_id == company.id
    end

    test "accepts jpeg, webp and pdf", %{admin: admin, company: company} do
      event = live_event(company, admin)

      for {bytes, name, type} <- [
            {@jpeg_magic <> "x", "a.jpg", "image/jpeg"},
            {@webp_magic <> "x", "b.webp", "image/webp"},
            {@pdf_magic <> "x", "c.pdf", "application/pdf"}
          ] do
        assert {:ok, doc} = Tugas.attach_evidence(event, tmp_upload(bytes, name), company, admin)
        assert doc.content_type == type
      end
    end

    test "stores the file under <company_id>/tugas and leaves it on disk", %{
      admin: admin,
      company: company
    } do
      event = live_event(company, admin)
      upload = tmp_upload(@pdf_magic <> "body", "statement.pdf")

      assert {:ok, doc} = Tugas.attach_evidence(event, upload, company, admin)

      assert doc.path =~ ~r{^#{company.id}/tugas/}
      assert doc.file_size == byte_size(@pdf_magic <> "body")
      assert File.exists?(Path.join(System.tmp_dir!(), doc.path))
    end

    test "rejects a type that is not on the allowlist", %{admin: admin, company: company} do
      event = live_event(company, admin)
      # A GIF: a real image, deliberately not on the allowlist.
      upload = tmp_upload("GIF89a" <> "x", "anim.gif")

      assert {:error, :unsupported_type} = Tugas.attach_evidence(event, upload, company, admin)
      refute File.exists?(Path.join([System.tmp_dir!(), company.id, "tugas"]))
    end

    test "rejects a file over 10MB", %{admin: admin, company: company} do
      event = live_event(company, admin)
      upload = tmp_upload(@png_magic <> :binary.copy(<<0>>, 10 * 1_000_000), "huge.png")

      assert {:error, :too_large} = Tugas.attach_evidence(event, upload, company, admin)
    end

    test "leaves no orphan file behind when the row cannot be written", %{
      admin: admin,
      company: company
    } do
      event = live_event(company, admin)
      # The event vanishes between the caller reading it and the attach landing.
      Repo.delete!(event)

      upload = tmp_upload(@png_magic <> "x", "late.png")

      assert {:error, %Ecto.Changeset{}} = Tugas.attach_evidence(event, upload, company, admin)

      tugas_dir = Path.join([System.tmp_dir!(), company.id, "tugas"])
      assert Path.wildcard(Path.join(tugas_dir, "**/*")) |> Enum.filter(&File.regular?/1) == []
    end

    test "refuses an event belonging to another company", %{admin: admin, company: company} do
      %{admin: other_admin, company: other_company} = billing_setup()
      event = live_event(other_company, other_admin)

      assert {:error, :not_found} =
               Tugas.attach_evidence(event, tmp_upload(@png_magic, "x.png"), company, admin)
    end

    test "lists evidence for an event", %{admin: admin, company: company} do
      event = live_event(company, admin)
      {:ok, _} = Tugas.attach_evidence(event, tmp_upload(@png_magic, "a.png"), company, admin)
      {:ok, _} = Tugas.attach_evidence(event, tmp_upload(@pdf_magic, "b.pdf"), company, admin)

      assert length(Tugas.list_event_documents(event.id, company, admin)) == 2
    end
  end
end
