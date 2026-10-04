defmodule FullCircle.NotesScansTest do
  use ExUnit.Case, async: true

  import FullCircle.NotesFixtures

  alias FullCircle.Notes.Scans

  setup do
    %{cid: Ecto.UUID.generate(), sid: Ecto.UUID.generate()}
  end

  test "pages are numbered in order, retake drops the last", %{cid: c, sid: s} do
    assert {:ok, 1} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    assert {:ok, 2} = Scans.add_page(c, s, real_jpeg_file(:gray))
    assert {:ok, 1} = Scans.drop_last(c, s)
    assert {:ok, 2} = Scans.add_page(c, s, real_jpeg_file(:gray))
    assert Scans.count(c, s) == 2
  end

  test "a non-JPEG page is refused alone; the scan keeps its pages", %{cid: c, sid: s} do
    {:ok, 1} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    assert {:error, :not_jpeg} = Scans.add_page(c, s, pdf_file())
    assert {:error, :not_jpeg} = Scans.add_page(c, s, jpeg_file())
    assert Scans.count(c, s) == 1
  end

  test "a scan id must be a UUID (it names a folder)", %{cid: c} do
    assert {:error, :invalid_scan} = Scans.add_page(c, "../../etc", real_jpeg_file(:rgb))
    assert Scans.count(c, "../../etc") == 0
  end

  test "more than max_pages is refused", %{cid: c, sid: s} do
    for _ <- 1..Scans.max_pages(), do: {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    assert {:error, :too_many_pages} = Scans.add_page(c, s, real_jpeg_file(:rgb))
  end

  test "finish builds one PDF; discard removes the folder", %{cid: c, sid: s} do
    {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:gray))
    assert {:ok, pdf} = Scans.finish(c, s)
    assert File.read!(pdf) =~ "/Count 2"
    assert :ok = Scans.discard(c, s)
    refute File.exists?(pdf)
    assert Scans.count(c, s) == 0
  end

  test "finish with no pages", %{cid: c, sid: s} do
    assert {:error, :no_pages} = Scans.finish(c, s)
  end

  test "prune_before removes only folders older than the cutoff", %{cid: c, sid: s} do
    old = Ecto.UUID.generate()
    {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    {:ok, _} = Scans.add_page(c, old, real_jpeg_file(:rgb))
    two_days_ago = System.os_time(:second) - 2 * 86_400
    File.touch!(Scans.dir(c, old), two_days_ago)

    assert Scans.prune_before(DateTime.add(DateTime.utc_now(), -1, :day)) >= 1
    assert Scans.count(c, old) == 0
    assert Scans.count(c, s) == 1
  end
end
