defmodule FullCircle.CommandPalette.NoteSearch do
  @moduledoc """
  Notes in the command palette.

  - `note <words>` / `notes <words>` — search notes only (`Notes.search/5`, so
    visibility is enforced by `Notes.visible_to/3`).
  - Every other non-action search ends with a "Search notes for …" row that
    opens the Notes page with the terms filled in. Note text is never mixed
    into document results.
  """

  import FullCircle.Authorization

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.Note
  alias FullCircle.CommandPalette.{Hit, Types}
  use Gettext, backend: FullCircleWeb.Gettext

  @prefix ~r/^notes?\s+(.*)$/is

  @doc "`{:ok, words}` when the query starts with the note prefix, else `:none`."
  def prefix(terms) do
    case Regex.run(@prefix, String.trim(terms)) do
      [_, words] -> {:ok, String.trim(words)}
      _ -> :none
    end
  end

  def search(company, user, words) do
    if words == "" or not can?(user, :view_notes, company) do
      []
    else
      notes = Notes.search(company, user, words, %{}, page: 1, per_page: Types.limit())

      subjects =
        notes
        |> Enum.filter(& &1.subject_type)
        |> Enum.map(&{&1.subject_type, &1.subject_id})
        |> Linkable.resolve_many(company, user)

      Enum.map(notes, &to_hit(&1, subjects, company))
    end
  end

  @doc "Row that opens the Notes page searching `words`; nil when not applicable."
  def fallback_hit(company, user, words) do
    if words != "" and can?(user, :view_notes, company) do
      query = URI.encode_query(%{"search[terms]" => words})

      %Hit{
        kind: :note_search,
        label: gettext("Notes"),
        doc_no: gettext("Search notes for “%{terms}”", terms: words),
        subtitle: gettext("Open the Notes page"),
        path: "/companies/#{company.id}/notes?#{query}"
      }
    end
  end

  defp to_hit(%Note{} = note, subjects, company) do
    subject =
      case Map.get(subjects, {note.subject_type, note.subject_id}) do
        {:ok, %{title: title}} when is_binary(title) -> title
        _ -> nil
      end

    date =
      note.inserted_at
      |> Timex.to_datetime(company.timezone)
      |> Calendar.strftime("%d/%m/%Y")

    author = note.author && note.author.email |> String.split("@") |> hd()

    %Hit{
      kind: :note,
      doc_type: "Note",
      doc_id: note.id,
      doc_no: Note.display_title(note),
      subtitle: [date, author, subject] |> Enum.reject(&is_nil/1) |> Enum.join(" · "),
      label: gettext("Note"),
      path: "/companies/#{company.id}/notes/#{note.id}"
    }
  end
end
