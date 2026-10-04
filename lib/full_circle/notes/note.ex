defmodule FullCircle.Notes.Note do
  @moduledoc """
  A note in the company memory.

  `subject_type`/`subject_id` point at the record the note is *about* (a
  `FullCircle.Linkable` type) or are both nil for a free-standing note.
  `visibility` is nil for public, else the roles allowed to read it; admin and
  the author always read. Every edit leaves a `NoteVersion` of what it replaced.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  alias FullCircle.Notes.NoteAttachment
  alias FullCircle.UserAccounts.User

  schema "notes" do
    field :title, :string
    field :body, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :visibility, {:array, :string}
    field :lock_version, :integer, default: 0
    field :deleted_at, :utc_datetime

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :author, User
    belongs_to :updated_by, User
    belongs_to :deleted_by, User
    belongs_to :reply_to, __MODULE__

    has_many :attachments, NoteAttachment,
      where: [removed_at: nil],
      preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @castable ~w(title body subject_type subject_id visibility reply_to_id)a

  # Admins read every note regardless of `visibility`, and guests cannot open
  # notes at all, so neither is a real choice. `["admin"]` on its own is the
  # stored form of "Private": only admins and the writer can read it.
  @choosable_roles ~w(manager supervisor cashier clerk auditor)
  @private ["admin"]

  @doc "Roles offered as visibility chips."
  def choosable_roles, do: @choosable_roles

  @doc "The stored `visibility` of a private note."
  def private_visibility, do: @private

  def private?(%{visibility: @private}), do: true
  def private?(_), do: false

  @doc "Every value a stored `visibility` list may hold (notes and tasks)."
  def visibility_values, do: @private ++ @choosable_roles

  @doc """
  `files?: true` when the note has files (already attached, or waiting in the
  write box's tray): then the text may be empty — a post of photos only.
  """
  def changeset(note, attrs, opts \\ []) do
    note
    |> cast(attrs, @castable)
    |> update_change(:title, &blank_to_nil/1)
    |> require_body(Keyword.get(opts, :files?, false))
    |> validate_length(:title, max: 120)
    |> validate_subject_pair()
    |> validate_visibility()
    |> check_constraint(:subject_id, name: :notes_subject_pair)
    |> check_constraint(:visibility, name: :notes_visibility_not_empty)
  end

  def display_title(%__MODULE__{title: t}) when is_binary(t) and t != "", do: t

  def display_title(%__MODULE__{body: body}) do
    case (body || "") |> String.trim() |> String.split("\n", parts: 2) |> hd() do
      # A post of files only (no title, no text).
      "" -> "📎 Files"
      line -> String.slice(line, 0, 120)
    end
  end

  defp require_body(cs, false), do: validate_required(cs, [:body])

  # cast turns "" into nil; the column is NOT NULL, so store "".
  defp require_body(cs, true) do
    if is_nil(get_field(cs, :body)), do: put_change(cs, :body, ""), else: cs
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp validate_subject_pair(cs) do
    type = get_field(cs, :subject_type)
    id = get_field(cs, :subject_id)

    if is_nil(type) == is_nil(id),
      do: cs,
      else: add_error(cs, :subject_id, "must be set together with subject type")
  end

  defp validate_visibility(cs) do
    case get_field(cs, :visibility) do
      nil ->
        cs

      [] ->
        add_error(cs, :visibility, "use nil for public")

      _roles ->
        validate_subset(cs, :visibility, visibility_values(), message: "has an invalid entry")
    end
  end
end
