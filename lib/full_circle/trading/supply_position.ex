defmodule FullCircle.Trading.SupplyPosition do
  use FullCircle.Schema
  import Ecto.Changeset

  # open     — no collection date yet
  # hold     — supplier halts collection
  # collect  — supplier allows collection
  # closed    — stock ended / collection finished
  @statuses ~w(open hold collect closed)

  # Still have stock (shown on position board / soft-hold targets)
  @active_statuses ~w(open hold collect)

  # Available on trip load/drop supply selects (not closed)
  # open may be auto-promoted to collect when a load is saved
  @loadable_statuses ~w(open hold collect)

  # Terminal — cannot transition to a different status once reached
  @terminal_statuses ~w(closed)

  schema "trading_supply_positions" do
    # Supply no: user-entered, or system gapless SUP-000001 when blank on create
    field :title, :string
    # Estimated date stock is available from
    field :available_from, :date
    # Supplier storage terms: last free-storage day (per-ton-per-day charges
    # start the day after). Manually entered any time — even after collection,
    # to verify a late storage bill. nil = no storage tracking.
    field :grace_period_end_date, :date
    field :quantity, :decimal
    field :unit_price, :decimal
    field :status, :string, default: "open"
    field :notes, :string

    field :supplier_name, :string, virtual: true
    field :good_name, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :supplier, FullCircle.Accounting.Contact
    belongs_to :good, FullCircle.Product.Good

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def active_statuses, do: @active_statuses
  def loadable_statuses, do: @loadable_statuses
  def terminal_statuses, do: @terminal_statuses
  def terminal?(status), do: status in @terminal_statuses

  @doc "Deprecated alias — use loadable_statuses/0"
  def collectable_statuses, do: @loadable_statuses

  def status_label("open"), do: "open — no collection date yet"
  def status_label("hold"), do: "hold — supplier halts collection"
  def status_label("collect"), do: "collect — supplier allows collection"
  def status_label("closed"), do: "closed — stock ended"
  def status_label(other), do: other

  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :title,
      :available_from,
      :grace_period_end_date,
      :quantity,
      :unit_price,
      :status,
      :notes,
      :company_id,
      :supplier_id,
      :good_id,
      :supplier_name,
      :good_name
    ])
    |> update_change(:title, &trim_title/1)
    # title optional on form validate (empty = auto SUP-###### on create);
    # create/update always set a non-blank title before insert/update
    |> validate_required([:quantity, :company_id, :supplier_id, :good_id, :status])
    |> validate_title_if_present()
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:quantity, greater_than: 0)
    |> unique_constraint(:title,
      name: :trading_supply_positions_unique_title_per_company
    )
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:supplier_id)
    |> foreign_key_constraint(:good_id)
  end

  defp trim_title(title) when is_binary(title), do: String.trim(title)
  defp trim_title(title), do: title

  # Blank title is allowed on the form (means auto-generate). Non-blank must stay non-blank after trim.
  defp validate_title_if_present(cs) do
    case get_change(cs, :title) || get_field(cs, :title) do
      t when is_binary(t) and t != "" -> validate_length(cs, :title, min: 1, max: 50)
      _ -> cs
    end
  end
end
