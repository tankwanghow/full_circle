defmodule FullCircle.NotesScanPdfTest do
  use ExUnit.Case, async: true

  import FullCircle.NotesFixtures

  alias FullCircle.Notes.ScanPdf

  defp out, do: Path.join(System.tmp_dir!(), "scan_#{System.unique_integer([:positive])}.pdf")

  test "jpeg_info reads size and components from the SOF marker" do
    assert {:ok, %{width: 40, height: 30, components: 3}} =
             ScanPdf.jpeg_info(File.read!(real_jpeg_file(:rgb)))

    assert {:ok, %{width: 30, height: 40, components: 1}} =
             ScanPdf.jpeg_info(File.read!(real_jpeg_file(:gray)))
  end

  test "jpeg_info refuses non-JPEG and truncated JPEG" do
    assert :error = ScanPdf.jpeg_info("%PDF-1.4 nope")
    assert :error = ScanPdf.jpeg_info(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 16>>)
    # magic bytes only (the old fixture): no SOF marker
    assert :error = ScanPdf.jpeg_info(File.read!(jpeg_file()))
  end

  test "build refuses no pages and a bad page" do
    assert {:error, :no_pages} = ScanPdf.build([], out())
    assert {:error, :bad_page} = ScanPdf.build([real_jpeg_file(:rgb), text_file()], out())
  end

  test "build writes a PDF whose xref offsets point at each object" do
    path = out()
    assert :ok = ScanPdf.build([real_jpeg_file(:rgb), real_jpeg_file(:gray)], path)
    pdf = File.read!(path)

    assert String.starts_with?(pdf, "%PDF-1.4")
    assert pdf =~ "/Count 2"
    assert pdf =~ "/ColorSpace /DeviceRGB"
    assert pdf =~ "/ColorSpace /DeviceGray"

    [_, xref_at] = Regex.run(~r/startxref\n(\d+)\n%%EOF\n$/, pdf)
    at = String.to_integer(xref_at)
    xref = binary_part(pdf, at, byte_size(pdf) - at)

    offsets =
      Regex.scan(~r/^(\d{10}) 00000 n $/m, xref)
      |> Enum.map(fn [_, o] -> String.to_integer(o) end)

    assert length(offsets) == 8

    for {off, n} <- Enum.with_index(offsets, 1) do
      assert binary_part(pdf, off, byte_size("#{n} 0 obj")) == "#{n} 0 obj"
    end
  end

  @tag :pdftoppm
  test "poppler renders every page" do
    path = out()
    :ok = ScanPdf.build([real_jpeg_file(:rgb), real_jpeg_file(:gray)], path)
    base = path <> "-render"
    assert {_, 0} = System.cmd("pdftoppm", ["-jpeg", "-r", "20", path, base])
    assert File.exists?(base <> "-1.jpg") and File.exists?(base <> "-2.jpg")
  end
end
