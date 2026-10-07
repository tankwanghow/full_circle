defmodule FullCircleWeb.ReceiptCapture do
  @moduledoc """
  Receipt capture on New Payment / New Purchase Invoice. The form owns a note
  tray filled from the phone (📱) or desktop (📎); the first file is read by
  `Receipts.Extract` and seeds the form's *empty* fields through
  `Receipts.Prefill`; Save attaches the tray as a 🧾 Receipt note on the new
  document inside the same transaction. Contract:
  `.claude/skills/receipt-capture.md`.
  """
  use FullCircleWeb, :html

  alias Ecto.Multi
  alias FullCircle.Notes
  alias FullCircle.Notes.Trays

  # Fields filled together or not at all: half a contact (a name the clerk
  # typed with the receipt's id) would save the wrong party.
  @groups [
    ~w(contact_name contact_id tax_id reg_no),
    ~w(funds_account_name funds_account_id)
  ]

  @doc """
  `seed_attrs` laid under `current` form params: a field is filled only when
  blank there (nil, "", or a zero amount), a group only when its first field
  is blank, and lines only when no current line has a good, quantity or price.
  """
  def merge_params(current, seed_attrs, detail_key) do
    seed = Map.new(seed_attrs, fn {k, v} -> {to_string(k), v} end)
    lines_key = to_string(detail_key)
    grouped = List.flatten(@groups)

    merged =
      Enum.reduce(@groups, current, fn [lead | _] = group, acc ->
        if blank?(acc[lead]) and Map.has_key?(seed, lead),
          do: Map.merge(acc, Map.take(seed, group)),
          else: acc
      end)

    merged =
      seed
      |> Map.drop([lines_key | grouped])
      |> Enum.reduce(merged, fn {k, v}, acc ->
        if blank?(acc[k]), do: Map.put(acc, k, v), else: acc
      end)

    if lines_blank?(current[lines_key]) and is_list(seed[lines_key]) do
      lines =
        seed[lines_key]
        |> Enum.with_index()
        |> Map.new(fn {line, i} -> {to_string(i), line} end)

      Map.put(merged, lines_key, lines)
    else
      merged
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(%Decimal{} = d), do: Decimal.eq?(d, 0)

  defp blank?(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {d, ""} -> Decimal.eq?(d, 0)
      _ -> false
    end
  end

  defp blank?(_), do: false

  defp lines_blank?(nil), do: true
  defp lines_blank?(lines) when is_map(lines), do: lines_blank?(Map.values(lines))

  defp lines_blank?(lines) when is_list(lines) do
    Enum.all?(lines, fn line ->
      blank?(line["good_name"]) and blank?(line["quantity"]) and blank?(line["unit_price"])
    end)
  end

  @doc "Appends the 🧾 Receipt note step when the tray has files and the user may write notes."
  def attach_multi(tray_id, doc_type, doc_key, com, user) do
    if Trays.has_files?(tray_id, com, user) and can_note?(com, user) do
      fn multi ->
        Multi.run(multi, :receipt_note, fn _repo, changes ->
          doc = Map.fetch!(changes, doc_key)

          %{
            "subject_type" => doc_type,
            "subject_id" => doc.id,
            "title" => "🧾 " <> gettext("Receipt"),
            "tray_id" => tray_id
          }
          |> Notes.create_note(com, user)
          |> case do
            {:ok, note} -> {:ok, note}
            :not_authorise -> {:error, :not_authorise}
            {:error, reason} -> {:error, reason}
          end
        end)
      end
    else
      &Function.identity/1
    end
  end

  @doc "True when the tray holds files that this user cannot attach as a note."
  def attach_blocked?(tray_id, com, user),
    do: Trays.has_files?(tray_id, com, user) and not can_note?(com, user)

  defp can_note?(com, user), do: FullCircle.Authorization.can?(user, :create_note, com)
end
