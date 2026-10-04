defmodule FullCircle.NotesFixtures do
  @moduledoc false

  def user_with_role(company, admin, role) do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(company, user, role, admin)
    user
  end

  # Real magic bytes; the rest is padding. Written fresh per call so a test
  # that moves or deletes one never breaks another.
  def jpeg_file, do: tmp_file(".jpg", <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, 64))
  def pdf_file, do: tmp_file(".pdf", "%PDF-1.4\n" <> :binary.copy("x", 64))

  # A one-page PDF poppler can actually render (pdf_file/0 only passes the
  # magic-byte sniff).
  def real_pdf_file do
    tmp_file(".pdf", """
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
    trailer<</Root 1 0 R>>
    %%EOF
    """)
  end

  def text_file, do: tmp_file(".jpg", "this is not an image at all")

  def big_file(bytes),
    do: tmp_file(".jpg", <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, bytes))

  def tray_fixture(company, user) do
    {:ok, tray} = FullCircle.Notes.Trays.open(Ecto.UUID.generate(), company, user)
    tray
  end

  defp tmp_file(ext, content) do
    path =
      Path.join(System.tmp_dir!(), "notes_fixture_#{System.unique_integer([:positive])}#{ext}")

    File.write!(path, content)
    path
  end

  def note_fixture(company, user, attrs \\ %{}) do
    {:ok, note} =
      FullCircle.Notes.create_note(Map.merge(%{"body" => "a note"}, attrs), company, user)

    note
  end
end
