defmodule FullCircle.CommandPalette.DateFilter do
  @moduledoc false

  import Ecto.Query, warn: false

  alias FullCircle.CommandPalette.Query

  @doc """
  Apply query date mode to an Ecto query whose first binding is the transaction.

  - `:none` — unchanged
  - `:on_or_before` — `doc_date <= date_to`
  - `:range` — `date_from <= doc_date <= date_to`
  """
  def apply(query, %Query{date_mode: :none}), do: query

  def apply(query, %Query{date_mode: :on_or_before, date_to: %Date{} = to}) do
    where(query, [t], t.doc_date <= ^to)
  end

  def apply(query, %Query{date_mode: :range, date_from: %Date{} = from, date_to: %Date{} = to}) do
    where(query, [t], t.doc_date >= ^from and t.doc_date <= ^to)
  end

  def apply(query, _), do: query
end
