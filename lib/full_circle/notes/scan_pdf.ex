defmodule FullCircle.Notes.ScanPdf do
  @moduledoc """
  Builds a PDF 1.4 file from JPEG pages, with no dependency: each JPEG is
  embedded as-is (`/DCTDecode`), so nothing is re-encoded. A page is sized
  from the image at 150 dpi and shrunk to fit A4 (portrait or landscape to
  match the image). Used for phone scans — see `FullCircle.Notes.Scans`.
  """

  @dpi 150
  @a4_short 595.28
  @a4_long 841.89

  @doc "Width, height and colour components from a JPEG's SOF marker."
  def jpeg_info(<<0xFF, 0xD8, rest::binary>>), do: scan(rest)
  def jpeg_info(_), do: :error

  # SOF0..SOF15 carry the frame size; C4 (DHT), C8 (JPG) and CC (DAC) share
  # the range but are not frames.
  defp scan(<<0xFF, m, _len::16, _precision, h::16, w::16, nc, _::binary>>)
       when m in 0xC0..0xCF and m not in [0xC4, 0xC8, 0xCC] do
    if nc in [1, 3] and w > 0 and h > 0,
      do: {:ok, %{width: w, height: h, components: nc}},
      else: :error
  end

  # Fill bytes before a marker.
  defp scan(<<0xFF, 0xFF, rest::binary>>), do: scan(<<0xFF, rest::binary>>)

  # Markers without a length.
  defp scan(<<0xFF, m, rest::binary>>) when m in 0xD0..0xD9 or m == 0x01, do: scan(rest)

  defp scan(<<0xFF, _m, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_::binary-size(skip), tail::binary>> -> scan(tail)
      _ -> :error
    end
  end

  defp scan(_), do: :error

  @doc "Writes the PDF of `jpeg_paths`, in order, to `out_path`."
  def build([], _out_path), do: {:error, :no_pages}

  def build(jpeg_paths, out_path) do
    with {:ok, pages} <- read_pages(jpeg_paths) do
      File.write(out_path, render(pages))
    end
  end

  defp read_pages(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, bin} <- File.read(path),
           {:ok, info} <- jpeg_info(bin) do
        {:cont, {:ok, [{bin, info} | acc]}}
      else
        _ -> {:halt, {:error, :bad_page}}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      error -> error
    end
  end

  # Objects: 1 catalog, 2 page tree, then per page i (0-based):
  # 3+3i page, 4+3i content stream, 5+3i image.
  defp render(pages) do
    n = length(pages)
    kids = Enum.map_join(0..(n - 1), " ", &"#{3 + 3 * &1} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{n} >>"
      ] ++
        Enum.flat_map(Enum.with_index(pages), fn {{bin, info}, i} ->
          {pw, ph} = page_size(info.width, info.height)
          content = "q #{fmt(pw)} 0 0 #{fmt(ph)} 0 0 cm /Im0 Do Q"
          space = if info.components == 1, do: "DeviceGray", else: "DeviceRGB"

          [
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{fmt(pw)} #{fmt(ph)}] " <>
              "/Resources << /XObject << /Im0 #{5 + 3 * i} 0 R >> >> /Contents #{4 + 3 * i} 0 R >>",
            ["<< /Length #{byte_size(content)} >>\nstream\n", content, "\nendstream"],
            [
              "<< /Type /XObject /Subtype /Image /Width #{info.width} /Height #{info.height} " <>
                "/ColorSpace /#{space} /BitsPerComponent 8 /Filter /DCTDecode " <>
                "/Length #{byte_size(bin)} >>\nstream\n",
              bin,
              "\nendstream"
            ]
          ]
        end)

    header = <<"%PDF-1.4\n%", 0xE2, 0xE3, 0xCF, 0xD3, "\n">>

    {body, offsets, _pos} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], byte_size(header)}, fn {obj, num}, {acc, offs, pos} ->
        chunk = ["#{num} 0 obj\n", obj, "\nendobj\n"]
        {[acc, chunk], [pos | offs], pos + IO.iodata_length(chunk)}
      end)

    xref_at = byte_size(header) + IO.iodata_length(body)
    size = length(objects) + 1

    # Every xref entry is exactly 20 bytes ("nnnnnnnnnn 00000 n \n").
    xref = [
      "xref\n0 #{size}\n0000000000 65535 f \n",
      offsets
      |> Enum.reverse()
      |> Enum.map(&(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n"))
    ]

    trailer = "trailer\n<< /Size #{size} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
    [header, body, xref, trailer]
  end

  defp page_size(w, h) do
    {wpt, hpt} = {w * 72 / @dpi, h * 72 / @dpi}
    {maxw, maxh} = if w > h, do: {@a4_long, @a4_short}, else: {@a4_short, @a4_long}
    scale = Enum.min([1.0, maxw / wpt, maxh / hpt])
    {wpt * scale, hpt * scale}
  end

  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
end
