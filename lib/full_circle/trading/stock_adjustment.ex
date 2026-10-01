defmodule FullCircle.Trading.StockAdjustment do
  @moduledoc """
  Stocktake correction to own-warehouse on-hand (physical only — no GL).

  Entered as a count: `qty = counted_qty - system_qty`, where `system_qty` is the
  book on-hand at entry. Immutable; a wrong count is fixed by another stocktake.
  """
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "trading_stock_adjustments" do
    field :reference_no, :string
    field :adjust_date, :date
    field :system_qty, :decimal
    field :counted_qty, :decimal
    field :qty, :decimal
    field :reason, :string
    # Form typeahead; resolved to good_id by the caller
    field :good_name, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :location, FullCircle.Trading.Location
    belongs_to :good, FullCircle.Product.Good
    belongs_to :created_by, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-entered fields only (`location_id`, `good_id`, `adjust_date`,
  `counted_qty`, `reason`). `system_qty`, `qty` and `reference_no` are set by
  `Trading.create_stock_adjustment/3` via `put_book_qty/2`.
  """
  def changeset(adjustment, attrs) do
    adjustment
    |> cast(attrs, [
      :company_id,
      :location_id,
      :good_id,
      :good_name,
      :adjust_date,
      :counted_qty,
      :reason
    ])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([
      :company_id,
      :location_id,
      :good_id,
      :adjust_date,
      :counted_qty,
      :reason
    ])
    |> validate_number(:counted_qty, greater_than_or_equal_to: 0)
    |> good_name_error()
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:location_id)
    |> foreign_key_constraint(:good_id)
    |> unique_constraint(:reference_no,
      name: :trading_stock_adjustments_unique_reference_no_per_company
    )
  end

  # The form shows good_name, not the hidden good_id — surface the error there.
  defp good_name_error(cs) do
    if cs.errors[:good_id] && get_field(cs, :good_name) not in [nil, ""],
      do: add_error(cs, :good_name, gettext("is not a known good")),
      else: cs
  end

  @doc """
  Records the book on-hand and, once a count is entered, the signed difference;
  a zero difference is an error.
  """
  def put_book_qty(%Ecto.Changeset{} = cs, system_qty) do
    cs = put_change(cs, :system_qty, system_qty)

    case get_field(cs, :counted_qty) do
      %Decimal{} = counted ->
        qty = Decimal.sub(counted, system_qty)
        cs = put_change(cs, :qty, qty)

        if Decimal.eq?(qty, 0),
          do: add_error(cs, :counted_qty, gettext("no difference from the system quantity")),
          else: cs

      _ ->
        cs
    end
  end
end
