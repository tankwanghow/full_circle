defmodule FullCircle.CommandPalette do
  @moduledoc """
  App-wide command palette (Ctrl/Cmd+K).

  - **Search:** document number, contact, type, dates, goods, deposits
  - **Actions:** `newinv`, `newpur`, `newdep`, …
  - **Empty:** create actions + client recents
  """

  alias FullCircle.CommandPalette.{ActionSearch, Groups, Hit, Router}

  def dispatch(company, user, text, page_context \\ %{}) do
    Router.dispatch(company, user, text, page_context)
  end

  def search(company, user, text) do
    case dispatch(company, user, text) do
      {:hits, hits} -> hits
      _ -> []
    end
  end

  @doc """
  Hits for an empty palette: create actions the user can run.
  Recents are merged on the client/LiveView from localStorage.
  """
  def empty_hits(company, user) do
    ActionSearch.search(company, user, "new")
  end

  def group_hits(hits), do: Groups.group(hits)

  @doc """
  Build recent hits from client payload maps.
  """
  def recents_from_payload(items) when is_list(items) do
    items
    |> Enum.take(8)
    |> Enum.flat_map(fn item ->
      path = item["path"] || item[:path]
      title = item["title"] || item[:title] || path
      label = item["label"] || item[:label] || "Recent"

      if is_binary(path) and path != "" do
        [
          %Hit{
            kind: :recent,
            doc_type: item["doc_type"] || item[:doc_type],
            doc_id: item["doc_id"] || item[:doc_id],
            doc_no: title,
            doc_date: nil,
            contact_name: nil,
            good_name: nil,
            label: label,
            path: path
          }
        ]
      else
        []
      end
    end)
  end

  def recents_from_payload(_), do: []

  @doc """
  Short token cheatsheet for empty palette footer / help strip.
  """
  def cheatsheet_lines do
    [
      "Search: INV-… · swee inv · dep maybank · rc funds cash",
      "Dates: 5/2/2026 (on/before) · 1/2/2026 - 14/2/2026",
      "Create: newinv newpur newrc newpv newcn newdn newjs newdep newrtn",
      "Keys: Ctrl+K palette · Ctrl+Shift+D dashboard · ↵ open"
    ]
  end
end
