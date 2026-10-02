defmodule FullCircle.Notes.ReplyBackfill do
  @moduledoc """
  One-off conversion of old note-on-note rows (a note whose subject is another
  note) into replies: `reply_to_id` = the true root (following parents while
  they are themselves about a note), subject and visibility = the root's. Each
  converted note gets a `note_versions` snapshot of its old state first.
  Idempotent: converted rows are no longer about a note. See the replies spec.
  """

  @roots_sql """
  WITH RECURSIVE chain AS (
    SELECT n.id AS note_id, n.subject_id AS parent_id, 1 AS depth, ARRAY[n.id] AS seen
    FROM notes n
    WHERE n.subject_type = 'Note' AND n.reply_to_id IS NULL
    UNION ALL
    SELECT c.note_id, p.subject_id, c.depth + 1, c.seen || p.id
    FROM chain c
    JOIN notes p ON p.id = c.parent_id
    WHERE p.subject_type = 'Note' AND NOT p.id = ANY(c.seen) AND c.depth < 50
  )
  SELECT DISTINCT ON (note_id) note_id, parent_id AS root_id
  FROM chain
  ORDER BY note_id, depth DESC
  """

  def run(repo) do
    %{rows: rows} = repo.query!(@roots_sql)
    pairs = for [note_id, root_id] <- rows, note_id != root_id, do: {note_id, root_id}

    repo.transaction(fn ->
      Enum.each(pairs, fn {note_id, root_id} ->
        repo.query!(
          """
          INSERT INTO note_versions
            (id, note_id, company_id, version, title, body, subject_type, subject_id,
             visibility, written_by_id, written_at, edited_by_id, inserted_at)
          SELECT gen_random_uuid(), n.id, n.company_id,
                 COALESCE((SELECT max(v.version) FROM note_versions v WHERE v.note_id = n.id), 0) + 1,
                 n.title, n.body, n.subject_type, n.subject_id, n.visibility,
                 n.updated_by_id, n.updated_at, n.updated_by_id, now()
          FROM notes n WHERE n.id = $1
          """,
          [note_id]
        )

        repo.query!(
          """
          UPDATE notes n
          SET reply_to_id = r.id, subject_type = r.subject_type,
              subject_id = r.subject_id, visibility = r.visibility
          FROM notes r
          WHERE n.id = $1 AND r.id = $2
          """,
          [note_id, root_id]
        )
      end)

      length(pairs)
    end)
  end
end
