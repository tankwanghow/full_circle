defmodule FullCircle.Notes.Scans do
  @moduledoc """
  A phone scan in progress: one folder of JPEG pages per scan
  (`<uploads>/<company>/scans/<scan_id>/001.jpg …`), no database rows. Pages
  upload as they are taken, so a phone page reloaded mid-scan loses nothing;
  `finish/2` builds one PDF (`ScanPdf`). The folder's mtime is its age for
  `prune_before/1` — a page write touches it.
  """

  alias FullCircle.Notes.{Attachments, ScanPdf}

  @max_pages 30

  def max_pages, do: @max_pages

  def dir(company_id, scan_id),
    do: Path.join([Attachments.uploads_dir(), company_id, "scans", scan_id])

  def add_page(company_id, scan_id, src) do
    with {:ok, scan_id} <- cast(scan_id),
         {:ok, %{size: size}} when size <= 10_000_000 <- File.stat(src),
         {:ok, bin} <- File.read(src),
         {:ok, _info} <- ScanPdf.jpeg_info(bin),
         n when n < @max_pages <- count(company_id, scan_id) do
      dir = dir(company_id, scan_id)
      File.mkdir_p!(dir)
      write_next(dir, bin, 3)
      File.touch!(dir)
      {:ok, count(company_id, scan_id)}
    else
      {:error, :invalid_scan} -> {:error, :invalid_scan}
      {:ok, %File.Stat{}} -> {:error, :too_large}
      n when is_integer(n) -> {:error, :too_many_pages}
      _ -> {:error, :not_jpeg}
    end
  end

  def drop_last(company_id, scan_id) do
    case pages(company_id, scan_id) do
      [] ->
        {:ok, 0}

      pages ->
        File.rm(List.last(pages))
        {:ok, length(pages) - 1}
    end
  end

  def count(company_id, scan_id), do: length(pages(company_id, scan_id))

  def finish(company_id, scan_id) do
    with {:ok, scan_id} <- cast(scan_id),
         [_ | _] = pages <- pages(company_id, scan_id),
         pdf = Path.join(dir(company_id, scan_id), "scan.pdf"),
         :ok <- ScanPdf.build(pages, pdf),
         {:ok, %{size: size}} <- File.stat(pdf) do
      if size <= Attachments.max_bytes(), do: {:ok, pdf}, else: {:error, :too_large}
    else
      [] -> {:error, :no_pages}
      {:error, reason} -> {:error, reason}
    end
  end

  def discard(company_id, scan_id) do
    with {:ok, scan_id} <- cast(scan_id), do: File.rm_rf(dir(company_id, scan_id))
    :ok
  end

  def prune_before(%DateTime{} = cutoff) do
    limit = DateTime.to_unix(cutoff)

    Path.join([Attachments.uploads_dir(), "*", "scans", "*"])
    |> Path.wildcard()
    |> Enum.filter(fn dir ->
      match?({:ok, %{mtime: m}} when m < limit, File.stat(dir, time: :posix))
    end)
    |> Enum.map(&File.rm_rf/1)
    |> length()
  end

  defp pages(company_id, scan_id) do
    case cast(scan_id) do
      {:ok, id} ->
        Path.join(dir(company_id, id), "[0-9][0-9][0-9].jpg") |> Path.wildcard() |> Enum.sort()

      _ ->
        []
    end
  end

  defp page_name(n), do: String.pad_leading(Integer.to_string(n), 3, "0") <> ".jpg"

  # Next number after the highest page, written :exclusive — two uploads at
  # once (or a racing retake) must never overwrite a page; the loser of a
  # race takes the next number.
  defp write_next(dir, bin, tries) do
    last =
      Path.join(dir, "[0-9][0-9][0-9].jpg")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename(".jpg") |> String.to_integer()))
      |> Enum.max(fn -> 0 end)

    case File.open(Path.join(dir, page_name(last + 1)), [:write, :exclusive, :binary]) do
      {:ok, io} ->
        IO.binwrite(io, bin)
        File.close(io)

      {:error, :eexist} when tries > 1 ->
        write_next(dir, bin, tries - 1)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "write scan page", path: dir
    end
  end

  # Only the canonical 36-character form: Ecto.UUID.cast/1 also accepts any
  # 16-byte binary ("../../../../tmp/"), and the id names a folder.
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  defp cast(scan_id) when is_binary(scan_id) do
    if Regex.match?(@uuid, scan_id),
      do: {:ok, String.downcase(scan_id)},
      else: {:error, :invalid_scan}
  end

  defp cast(_), do: {:error, :invalid_scan}
end
