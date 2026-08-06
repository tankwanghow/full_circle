defmodule FullCircle.CommandPalette.Groups do
  @moduledoc false

  @doc """
  Group hits for UI: Actions, Contacts, Documents (stable order).
  Returns `[{section_atom, [Hit.t()]}]` omitting empty sections.
  """
  def group(hits) when is_list(hits) do
    actions = Enum.filter(hits, &(&1.kind == :action))
    contacts = Enum.filter(hits, &(&1.kind == :contact))
    recents = Enum.filter(hits, &(&1.kind == :recent))
    documents = Enum.filter(hits, &(&1.kind == :document))

    [
      {:actions, actions},
      {:recents, recents},
      {:contacts, contacts},
      {:documents, documents}
    ]
    |> Enum.reject(fn {_sec, list} -> list == [] end)
  end

  @doc """
  Flat index → hit, for keyboard selection across grouped sections.
  """
  def flatten(groups) do
    Enum.flat_map(groups, fn {_sec, hits} -> hits end)
  end

  def section_label(:actions), do: "Actions"
  def section_label(:recents), do: "Recent"
  def section_label(:contacts), do: "Contacts"
  def section_label(:documents), do: "Documents"
  def section_label(_), do: ""
end
