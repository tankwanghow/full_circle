defmodule FullCircle.CommandPalette.ActionSearch do
  @moduledoc """
  Create-document actions via compound tokens (`newinv`, `newpur`, `newcn`, …).

  Only matches a **single token** (no spaces) so a contact named "New Asia"
  never opens create flows.
  """

  import FullCircle.Authorization

  alias FullCircle.CommandPalette.{Hit, Types}

  @doc """
  Return matching create actions the user is allowed to run.
  """
  def search(company, user, terms) when is_binary(terms) do
    raw = String.trim(terms)

    cond do
      raw == "" ->
        []

      # Multi-word input is document/contact search only
      String.match?(raw, ~r/\s/) ->
        []

      true ->
        needle = Types.normalize_token(raw)

        if needle == "" or String.length(needle) < Types.min_length() do
          []
        else
          match_actions(company, user, needle)
        end
    end
  end

  defp match_actions(company, user, needle) do
    Types.create_specs()
    |> Enum.filter(fn {keys, _type, action, _label, _route} ->
      can?(user, action, company) and Enum.any?(keys, &key_match?(&1, needle))
    end)
    |> Enum.map(fn {keys, doc_type, _action, label, route} ->
      primary = List.first(keys)

      %Hit{
        kind: :action,
        doc_type: doc_type,
        doc_id: nil,
        doc_no: label,
        doc_date: nil,
        contact_name: primary,
        label: "New",
        path: "/companies/#{company.id}/#{route}/new"
      }
    end)
  end

  # "new" → all new* actions; "newi" → newinv; "newinv" → exact/prefix
  defp key_match?(key, needle) do
    String.starts_with?(key, needle) or String.starts_with?(needle, key)
  end
end
