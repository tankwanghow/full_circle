defmodule FullCircle.Tugas do
  @moduledoc """
  Duties: what has to get done, who moved it along, and what proves it.

  Three things hang off a duty:

    * **events** — an append-only trail (`progress`, `done`, `skip`, `linked`,
      `unlinked`, `end_series`). Events are the record; the duty row is just
      the current state.
    * **evidence** — files attached to an event.
    * **documents** — links to real FullCircle documents (`duty_documents`).
      One duty can point at many documents.

  Closing a cycle and spawning the next happen in one `Ecto.Multi`, so a duty
  series can never be left with zero live cycles or two.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  require Logger

  alias Ecto.Multi
  alias FullCircle.Repo
  alias FullCircle.StdInterface
  alias FullCircle.Sys
  alias FullCircle.Tugas.Duty
  alias FullCircle.Tugas.DutyDocument
  alias FullCircle.Tugas.DutyEvent
  alias FullCircle.Tugas.DutyEventDocument

  @doc """
  Document types a duty may be linked to.

  Deliberately a whitelist: `duty_documents.doc_id` carries no foreign key, so
  this list is the only thing keeping the column pointed at real tables.
  """
  def document_types, do: ~w(Payment)

  def query(Duty, company, user) do
    from(d in Duty,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == d.company_id,
      select: d
    )
  end

  def query(DutyEvent, company, user) do
    from(e in DutyEvent,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == e.company_id,
      select: e
    )
  end

  def query(DutyDocument, company, user) do
    from(l in DutyDocument,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == l.company_id,
      select: l
    )
  end

  def query(DutyEventDocument, company, user) do
    from(d in DutyEventDocument,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == d.company_id,
      select: d
    )
  end

  def get_duty!(id, com, user),
    do: Repo.one!(from(d in query(Duty, com, user), where: d.id == ^id))

  def get_duty(id, com, user), do: Repo.one(from(d in query(Duty, com, user), where: d.id == ^id))

  # --- DUTIES ---------------------------------------------------------------

  def create_duty(attrs, com, user) do
    attrs =
      attrs
      |> FullCircle.Helpers.key_to_string()
      |> Map.put_new("series_id", Ecto.UUID.generate())
      |> Map.put("status", "active")

    StdInterface.create(Duty, "duty", attrs, com, user)
  end

  @doc """
  Edits the descriptive fields of a duty.

  Status is deliberately not editable here: a duty leaves `active` only through
  `complete_duty/4` or `skip_duty/4`, which also decide whether the next cycle
  is spawned. Letting a plain edit write `status` would strand a series with no
  live cycle.
  """
  def update_duty(%Duty{} = duty, attrs, com, user) do
    attrs =
      attrs
      |> FullCircle.Helpers.key_to_string()
      |> Map.drop(~w(status series_id series_ended_at company_id))

    with true <- can?(user, :update_duty, com) || :not_authorise do
      # Dropping the protected keys can leave nothing to write. Sys.Log
      # requires a non-blank delta, so an empty update would fail the
      # transaction on the log insert rather than being the no-op it is.
      if StdInterface.changeset(Duty, duty, attrs, com).changes == %{} do
        {:ok, duty}
      else
        StdInterface.update(Duty, "duty", duty, attrs, com, user)
      end
    end
  end

  # --- EVENTS ---------------------------------------------------------------

  @doc """
  Appends a `progress` note to a live duty.

  Progress on a closed duty is almost always a note meant for the cycle that
  has since been spawned, so it is refused rather than silently filed against
  history.
  """
  def add_progress(%Duty{} = duty, attrs, com, user) do
    with true <- can?(user, :create_duty_event, com) || :not_authorise,
         %Duty{status: "active"} <- get_duty(duty.id, com, user) do
      Multi.new()
      |> insert_event_multi(:duty_event, duty.id, "progress", note_of(attrs), com, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{duty_event: event}} -> {:ok, event}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    else
      :not_authorise -> :not_authorise
      _ -> {:error, :not_live}
    end
  end

  # Every event insert is paired with a Sys log entry, so the trail survives
  # even if the event row is later corrected or deleted inside the 48h window.
  defp insert_event_multi(multi, name, duty_id, action, note, com, user) do
    multi
    |> Multi.insert(
      name,
      DutyEvent.changeset(%DutyEvent{}, %{
        "action" => action,
        "note" => note,
        "duty_id" => duty_id,
        "company_id" => com.id,
        "user_id" => user.id
      })
    )
    |> Multi.insert("#{name}_log", fn %{^name => event} ->
      Sys.log_changeset(
        String.to_atom("create_duty_event_" <> action),
        event,
        %{"action" => action, "note" => note, "duty_id" => duty_id},
        com,
        user
      )
    end)
  end

  def list_duty_events(duty_id, com, user) do
    Repo.all(
      from(e in query(DutyEvent, com, user),
        where: e.duty_id == ^duty_id,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp note_of(attrs), do: attrs["note"] || attrs[:note]

  # --- CLOSING A CYCLE ------------------------------------------------------

  @doc """
  Marks the live cycle done and, unless the series has been ended, spawns the
  next one.

  Returns `{:ok, %{duty: closed, next_duty: next_or_nil}}`.
  """
  def complete_duty(duty_id, attrs, com, user),
    do: close_cycle(duty_id, "done", "done", :complete_duty, attrs, com, user)

  @doc """
  Marks the live cycle skipped and, unless the series has been ended, spawns
  the next one. A skipped cycle still advances the series — that is the whole
  point of skipping rather than deleting.
  """
  def skip_duty(duty_id, attrs, com, user),
    do: close_cycle(duty_id, "skipped", "skip", :skip_duty, attrs, com, user)

  defp close_cycle(duty_id, status, action, auth_action, attrs, com, user) do
    note = note_of(attrs)

    with true <- can?(user, auth_action, com) || :not_authorise do
      Multi.new()
      |> Multi.run(:live_duty, fn repo, _ -> lock_live_duty(repo, duty_id, com) end)
      # The close must be written before the spawn, or the partial unique index
      # on (series_id) WHERE status='active' would see two live cycles at once.
      |> Multi.update(:duty, fn %{live_duty: duty} ->
        Duty.changeset(duty, %{"status" => status})
      end)
      |> Multi.insert("#{auth_action}_log", fn %{duty: duty} ->
        Sys.log_changeset(auth_action, duty, %{"status" => status, "note" => note}, com, user)
      end)
      |> insert_event_multi(:duty_event, duty_id, action, note, com, user)
      |> Multi.run(:next_duty, fn repo, %{live_duty: duty} -> spawn_next(repo, duty) end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} -> {:ok, changes}
        {:error, :live_duty, :not_live, _} -> {:error, :not_live}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    end
  end

  # SELECT ... FOR UPDATE inside the transaction: two concurrent closes of the
  # same cycle serialise here, and whichever arrives second re-reads a row that
  # is no longer active and gets {:error, :not_live} instead of double-closing
  # and double-spawning.
  #
  # Scoped by company_id rather than by the user_company subquery because
  # Postgres refuses FOR UPDATE on a query that joins a subquery. Membership is
  # already established by the can?/3 check above, which reports "disable" for
  # a user with no row in this company.
  defp lock_live_duty(repo, duty_id, com) do
    from(d in Duty,
      where: d.id == ^duty_id and d.company_id == ^com.id,
      lock: "FOR UPDATE"
    )
    |> repo.one()
    |> case do
      %Duty{status: "active"} = duty -> {:ok, duty}
      _ -> {:error, :not_live}
    end
  end

  defp spawn_next(_repo, %Duty{recur_unit: nil}), do: {:ok, nil}
  defp spawn_next(_repo, %Duty{series_ended_at: %DateTime{}}), do: {:ok, nil}

  defp spawn_next(repo, %Duty{} = duty) do
    repo.insert(
      Duty.changeset(%Duty{}, %{
        "title" => duty.title,
        "descriptions" => duty.descriptions,
        "due_date" => Duty.next_due_date(duty.due_date, duty.recur_unit, duty.recur_every),
        "status" => "active",
        "series_id" => duty.series_id,
        "recur_unit" => duty.recur_unit,
        "recur_every" => duty.recur_every,
        "company_id" => duty.company_id
      })
    )
  end

  @doc """
  Stops a series from ever spawning again.

  Deliberately does not close the live cycle: the work that is already due
  still has to be finished or skipped. Every row of the series is stamped so
  the fact is visible from any cycle, not only the last one.
  """
  def end_series(%Duty{} = duty, com, user) do
    with true <- can?(user, :end_duty_series, com) || :not_authorise,
         %Duty{} = duty <- get_duty(duty.id, com, user) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Multi.new()
      |> Multi.update_all(
        :series,
        from(d in Duty,
          where:
            d.series_id == ^duty.series_id and d.company_id == ^com.id and
              is_nil(d.series_ended_at)
        ),
        set: [series_ended_at: now, updated_at: now]
      )
      |> insert_event_multi(:duty_event, duty.id, "end_series", nil, com, user)
      |> Multi.insert("end_duty_series_log", fn _ ->
        Sys.log_changeset(
          :end_duty_series,
          duty,
          %{"series_id" => duty.series_id, "series_ended_at" => now},
          com,
          user
        )
      end)
      |> Multi.run(:duty, fn repo, _ -> {:ok, repo.get!(Duty, duty.id)} end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} -> {:ok, changes}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    else
      :not_authorise -> :not_authorise
      nil -> {:error, :not_found}
    end
  end

  # --- DOCUMENT LINKS -------------------------------------------------------

  def list_duty_documents(duty_id, com, user) do
    Repo.all(
      from(l in query(DutyDocument, com, user),
        where: l.duty_id == ^duty_id,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
  end

  @doc """
  Points a duty at a document.

  Deliberately allowed on a closed duty: the document that proves a duty was
  done is often posted after someone ticked it off, and refusing the link
  would push that evidence out of the trail entirely.
  """
  def link_document(%Duty{} = duty, attrs, com, user) do
    attrs = FullCircle.Helpers.key_to_string(attrs)

    changeset =
      DutyDocument.changeset(%DutyDocument{}, %{
        "doc_type" => attrs["doc_type"],
        "doc_id" => attrs["doc_id"],
        "doc_no" => attrs["doc_no"],
        "duty_id" => duty.id,
        "company_id" => com.id,
        "user_id" => user.id
      })

    with true <- can?(user, :link_duty_document, com) || :not_authorise do
      Multi.new()
      |> Multi.insert(:duty_document, changeset)
      |> Multi.merge(fn %{duty_document: link} ->
        Multi.new()
        |> insert_event_multi(
          :duty_event,
          duty.id,
          "linked",
          DutyDocument.label(link),
          com,
          user
        )
      end)
      |> Multi.insert("link_duty_document_log", fn %{duty_document: link} ->
        Sys.log_changeset(
          :link_duty_document,
          link,
          %{"doc_type" => link.doc_type, "doc_no" => link.doc_no, "duty_id" => duty.id},
          com,
          user
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{duty_document: link}} -> {:ok, link}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    end
  end

  @doc """
  Removes a document link, leaving an `unlinked` event behind.

  The link row is deleted rather than flagged; the event is what preserves the
  fact that it once existed, which is why unlinking is supervisory.
  """
  def unlink_document(%DutyDocument{} = link, com, user) do
    with true <- can?(user, :unlink_duty_document, com) || :not_authorise,
         %DutyDocument{} = link <- get_duty_document(link.id, com, user) do
      Multi.new()
      |> insert_event_multi(
        :duty_event,
        link.duty_id,
        "unlinked",
        DutyDocument.label(link),
        com,
        user
      )
      |> Multi.delete(:duty_document, link)
      |> Multi.insert("unlink_duty_document_log", fn _ ->
        Sys.log_changeset(
          :unlink_duty_document,
          link,
          %{"doc_type" => link.doc_type, "doc_no" => link.doc_no, "duty_id" => link.duty_id},
          com,
          user
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{duty_document: link}} -> {:ok, link}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    else
      :not_authorise -> :not_authorise
      nil -> {:error, :not_found}
    end
  end

  def get_duty_document(id, com, user),
    do: Repo.one(from(l in query(DutyDocument, com, user), where: l.id == ^id))

  @doc """
  Finds duties whose title or descriptions contain `terms`.

  `terms` is escaped before it reaches the LIKE pattern, so a user typing "100%"
  searches for a literal percent sign rather than matching every duty starting
  with "100".
  """
  def search_duties(terms, com, user, opts \\ [])

  def search_duties(terms, _com, _user, _opts) when terms in [nil, ""], do: []

  def search_duties(terms, com, user, opts) do
    pattern = "%#{FullCircle.CommandPalette.Types.escape_like(terms)}%"
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 50)

    q =
      from(d in query(Duty, com, user),
        where: ilike(d.title, ^pattern) or ilike(d.descriptions, ^pattern),
        order_by: [asc_nulls_last: d.due_date, asc: d.inserted_at],
        limit: ^limit
      )

    q = if status, do: from(d in q, where: d.status == ^status), else: q

    Repo.all(q)
  end

  # --- EVIDENCE -------------------------------------------------------------

  @evidence_max_bytes 10_000_000

  @doc "MIME types a piece of evidence is allowed to be, after sniffing."
  def evidence_content_types, do: ~w(image/jpeg image/png image/webp application/pdf)

  @doc "Largest evidence file accepted, in bytes."
  def evidence_max_bytes, do: @evidence_max_bytes

  def list_event_documents(event_id, com, user) do
    Repo.all(
      from(d in query(DutyEventDocument, com, user),
        where: d.duty_event_id == ^event_id,
        order_by: [asc: d.inserted_at]
      )
    )
  end

  @doc """
  Attaches a file to a duty event.

  `upload` is `%{path: <file on disk>, file_name: <name to show>}`, which is
  what `consume_uploaded_entry/3` hands over.

  The content type is sniffed from the first bytes of the file and the claimed
  type is ignored entirely. Size is checked with `File.stat/1` before anything
  is read or copied, so an oversized upload costs one stat.

  Returns `{:error, :too_large}`, `{:error, :unsupported_type}`,
  `{:error, :not_found}` or `{:error, changeset}`. On any failure after the
  copy the destination file is removed, so a rejected row never leaves an
  unreferenced file on the volume.
  """
  def attach_evidence(%DutyEvent{} = event, upload, com, user) do
    src = upload[:path] || upload["path"]
    file_name = upload[:file_name] || upload["file_name"]

    with true <- can?(user, :create_duty_event_document, com) || :not_authorise,
         :ok <- assert_event_in_company(event, com),
         {:ok, size} <- assert_size(src),
         {:ok, content_type} <- sniff(src) do
      write_evidence(event, src, file_name, size, content_type, com, user)
    end
  end

  defp assert_event_in_company(%DutyEvent{company_id: cid}, %{id: cid}), do: :ok
  defp assert_event_in_company(_, _), do: {:error, :not_found}

  defp assert_size(src) do
    case File.stat(src) do
      {:ok, %{size: size}} when size <= @evidence_max_bytes -> {:ok, size}
      {:ok, _} -> {:error, :too_large}
      {:error, _} -> {:error, :not_found}
    end
  end

  # Magic bytes only. A claimed content type is trivially wrong (a phone that
  # sends every picture as application/octet-stream) and trivially forged, and
  # this column decides what the file is later served back as.
  defp sniff(src) do
    case File.open(src, [:read, :binary], &IO.binread(&1, 16)) do
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, "image/jpeg"}
      {:ok, <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>} -> {:ok, "image/png"}
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> {:ok, "image/webp"}
      {:ok, <<"%PDF-", _::binary>>} -> {:ok, "application/pdf"}
      {:ok, _} -> {:error, :unsupported_type}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp write_evidence(event, src, file_name, size, content_type, com, user) do
    rel = evidence_rel_path(event, com, content_type)
    abs = Path.join(uploads_dir(), rel)

    File.mkdir_p!(Path.dirname(abs))
    File.cp!(src, abs)

    Multi.new()
    |> Multi.insert(
      :duty_event_document,
      DutyEventDocument.changeset(%DutyEventDocument{}, %{
        "file_name" => file_name,
        "content_type" => content_type,
        "file_size" => size,
        "path" => rel,
        "duty_event_id" => event.id,
        "company_id" => com.id
      })
    )
    |> Multi.insert("create_duty_event_document_log", fn %{duty_event_document: doc} ->
      Sys.log_changeset(
        :create_duty_event_document,
        doc,
        %{"file_name" => file_name, "content_type" => content_type, "file_size" => size},
        com,
        user
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{duty_event_document: doc}} ->
        {:ok, doc}

      {:error, _, failed_value, _} ->
        # The row is what makes the file findable. Without one it is garbage on
        # the volume that nothing will ever clean up, so drop it here.
        File.rm(abs)
        {:error, failed_value}
    end
  rescue
    e in [File.Error, File.CopyError] ->
      Logger.error("tugas evidence copy failed: #{Exception.message(e)}")
      {:error, :copy_failed}
  end

  defp evidence_rel_path(event, com, content_type) do
    Path.join([
      com.id,
      "tugas",
      event.id,
      Ecto.UUID.generate() <> extension_for(content_type)
    ])
  end

  defp extension_for("image/jpeg"), do: ".jpg"
  defp extension_for("image/png"), do: ".png"
  defp extension_for("image/webp"), do: ".webp"
  defp extension_for("application/pdf"), do: ".pdf"

  defp uploads_dir, do: Application.get_env(:full_circle, :uploads_dir)

  # --- CORRECTIONS ----------------------------------------------------------

  @correction_window_hours 48

  def correction_window_hours, do: @correction_window_hours

  @doc """
  Fixes the note on a `progress` event.

  Only the note changes; `action` is dropped from the attrs, because an event's
  kind is decided by the state machine that wrote it and rewriting it would put
  the trail out of step with the duty row.

  The author may correct their own event for #{@correction_window_hours} hours.
  After that — or on somebody else's event at any age — it takes
  `:correct_others_duty_event`, which is the supervisory override.
  """
  def correct_duty_event(%DutyEvent{} = event, attrs, com, user) do
    note = note_of(FullCircle.Helpers.key_to_string(attrs))

    with {:ok, event} <- correctable(event, com, user),
         {:ok, updated} <-
           Repo.update(DutyEvent.changeset(event, %{"note" => note})),
         {:ok, _} <-
           Repo.insert(
             Sys.log_changeset(
               :correct_duty_event,
               updated,
               %{"note" => note, "was" => event.note},
               com,
               user
             )
           ) do
      {:ok, updated}
    end
  end

  @doc """
  Retracts a `progress` event, and takes its evidence off the volume with it.

  Same window and same override as `correct_duty_event/4`. The evidence rows
  cascade from the foreign key; the files would not, so they are removed here.
  """
  def delete_duty_event(%DutyEvent{} = event, com, user) do
    with {:ok, event} <- correctable(event, com, user) do
      paths = Enum.map(list_event_documents(event.id, com, user), & &1.path)

      Multi.new()
      |> Multi.delete(:duty_event, event)
      |> Multi.insert("delete_duty_event_log", fn _ ->
        Sys.log_changeset(
          :delete_duty_event,
          event,
          %{"action" => event.action, "note" => event.note, "duty_id" => event.duty_id},
          com,
          user
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{duty_event: event}} ->
          # Only once the rows are certainly gone. A file removed ahead of a
          # rolled-back delete would leave a row pointing at nothing, which is
          # worse than the orphan it was trying to avoid.
          Enum.each(paths, &File.rm(Path.join(uploads_dir(), &1)))
          {:ok, event}

        {:error, _, failed_value, _} ->
          {:error, failed_value}
      end
    end
  end

  # Structural events (done, skip, linked, unlinked, end_series) are written by
  # the state machine and are what the duty row is derived from. Retracting a
  # "done" would not reopen the duty, it would only make the trail lie.
  defp correctable(%DutyEvent{action: action}, _com, _user) when action != "progress",
    do: {:error, :not_correctable}

  defp correctable(%DutyEvent{} = event, com, user) do
    case get_duty_event(event.id, com, user) do
      nil ->
        {:error, :not_found}

      %DutyEvent{} = event ->
        cond do
          own?(event, user) and within_window?(event) ->
            if can?(user, :create_duty_event, com), do: {:ok, event}, else: :not_authorise

          can?(user, :correct_others_duty_event, com) ->
            {:ok, event}

          own?(event, user) ->
            {:error, :window_closed}

          true ->
            {:error, :not_author}
        end
    end
  end

  defp own?(%DutyEvent{user_id: uid}, %{id: uid}), do: true
  defp own?(_, _), do: false

  defp within_window?(%DutyEvent{inserted_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) <= @correction_window_hours * 3600
  end

  def get_duty_event(id, com, user),
    do: Repo.one(from(e in query(DutyEvent, com, user), where: e.id == ^id))
end
