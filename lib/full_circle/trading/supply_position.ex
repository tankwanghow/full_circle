defmodule FullCircle.Trading.SupplyPosition do
  use FullCircle.Schema
  import Ecto.Changeset

  # open     — collection date not confirmed
  # hold     — stock exists; supplier is holding collection
  # collect  — stock exists; supplier allows collection
  # closed    — stock ended / collection finished
  @statuses ~w(open hold collect closed)

  # Still have stock (shown on position board / soft-hold targets)
  @active_statuses ~w(open hold collect)

  # Supplier allows lift (trip load supply options)
  @collectable_statuses ~w(collect)

  schema "trading_supply_positions" do
    # Single free-text identity: vessel name, PO ref, short description, etc.
    field :title, :string
    # Estimated date stock is available to load
    field :available_from, :date
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
  def collectable_statuses, do: @collectable_statuses

  def status_label("open"), do: "open — collection date not confirmed"
  def status_label("hold"), do: "hold — stock exists, collection held by supplier"
  def status_label("collect"), do: "collect — stock exists, supplier allows collection"
  def status_label("closed"), do: "closed — stock ended"
  def status_label(other), do: other

  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :title,
      :available_from,
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
    |> validate_required([:title, :quantity, :company_id, :supplier_id, :good_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:supplier_id)
    |> foreign_key_constraint(:good_id)
  end

  defp trim_title(title) when is_binary(title), do: String.trim(title)
  defp trim_title(title), do: title
end
