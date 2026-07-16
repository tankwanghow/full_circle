defmodule FullCircle.BankReconciliation.PdfText do
  @moduledoc """
  Extracts text from PDF files using poppler-utils (`pdfinfo`, `pdftotext`).
  Used to batch large bank statement PDFs page-by-page for LLM parsing.
  """

  @doc "Returns {:ok, [page_text, ...]} or {:error, reason}."
  def pages(pdf_path) do
    with {:ok, _} <- validate_path(pdf_path),
         {:ok, page_count} <- page_count(pdf_path),
         pages <- extract_pages(pdf_path, page_count),
         non_empty <- Enum.filter(pages, &(String.trim(&1) != "")) do
      if non_empty == [] do
        {:error, "No text extracted from PDF"}
      else
        {:ok, non_empty}
      end
    end
  end

  @doc "Returns {:ok, full_text} or {:error, reason}."
  def extract(pdf_path) do
    case pages(pdf_path) do
      {:ok, pages} -> {:ok, Enum.join(pages, "\n\n")}
      error -> error
    end
  end

  @doc "Returns true when pdftotext and pdfinfo are available on PATH."
  def available? do
    pdfinfo_available?() and pdftotext_available?()
  end

  defp validate_path(path) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, "PDF file not found"}
    end
  end

  defp page_count(pdf_path) do
    case System.find_executable("pdfinfo") do
      nil ->
        {:error, "pdfinfo not found (install poppler-utils)"}

      _ ->
        case System.cmd("pdfinfo", [pdf_path], stderr_to_stdout: true) do
          {output, 0} ->
            case Regex.run(~r/Pages:\s+(\d+)/, output) do
              [_, n] -> {:ok, String.to_integer(n)}
              _ -> {:error, "Could not determine PDF page count"}
            end

          {output, _} ->
            {:error, "pdfinfo failed: #{String.slice(output, 0, 200)}"}
        end
    end
  end

  defp extract_pages(pdf_path, count) do
    Enum.map(1..count, fn page ->
      case System.cmd(
             "pdftotext",
             [
               "-f",
               Integer.to_string(page),
               "-l",
               Integer.to_string(page),
               "-layout",
               pdf_path,
               "-"
             ],
             stderr_to_stdout: true
           ) do
        {text, 0} -> text
        _ -> ""
      end
    end)
  end

  defp pdfinfo_available?, do: is_binary(System.find_executable("pdfinfo"))
  defp pdftotext_available?, do: is_binary(System.find_executable("pdftotext"))
end
