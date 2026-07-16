defmodule FullCircle.Trading.SalesPosition do
  use FullCircle.Schema
  import Ecto.Changeset

  alias FullCircle.Repo
  alias FullCircle.Trading.SupplyPosition

  # draft      — not yet committed
  # open       — active commitment
  # hold       — on hold (paused delivery)
  # fulfilled  — done (may be short)
  # cancelled   — cancelled
  @statuses ~w(draft open hold fulfilled cancelled)

  # Still open commitments (open sales board, soft hold, trip drop targets)
  @active_statuses ~w(draft open hold)

  schema "trading_sales_positions" do
    # Single free-text identity: deal name, customer PO #, short description, etc.
    field :title, :string
    # Estimated date stock is needed / to be delivered
    field :available_from, :date
    field :quantity, :decimal
    field :unit_price, :decimal
    field :status, :string, default: "draft"
    field :notes, :string
    field :fulfilled_note, :string

    field :customer_name, :string, virtual: true
    field :good_name, :string, virtual: true
    field :preferred_supply_title, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :customer, FullCircle.Accounting.Contact
    belongs_to :good, FullCircle.Product.Good
    belongs_to :preferred_supply, SupplyPosition

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def active_statuses, do: @active_statuses

  def status_label("draft"), do: "draft — not yet committed"
  def status_label("open"), do: "open — active commitment"
  def status_label("hold"), do: "hold — delivery paused"
  def status_label("fulfilled"), do: "fulfilled — done"
  def status_label("cancelled"), do: "cancelled"
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
      :fulfilled_note,
      :company_id,
      :customer_id,
      :good_id,
      :preferred_supply_id,
      :customer_name,
      :good_name,
      :preferred_supply_title
    ])
    |> update_change(:title, &trim_title/1)
    |> validate_required([:title, :quantity, :company_id, :customer_id, :good_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:quantity, greater_than: 0)
    |> validate_preferred_supply_same_company()
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:customer_id)
    |> foreign_key_constraint(:good_id)
    |> foreign_key_constraint(:preferred_supply_id)
  end

  defp trim_title(title) when is_binary(title), do: String.trim(title)
  defp trim_title(title), do: title

  defp validate_preferred_supply_same_company(changeset) do
    supply_id = get_field(changeset, :preferred_supply_id)
    company_id = get_field(changeset, :company_id)

    cond do
      is_nil(supply_id) or is_nil(company_id) ->
        changeset

      true ->
        case Repo.get(SupplyPosition, supply_id) do
          %{company_id: ^company_id} ->
            changeset

          nil ->
            add_error(changeset, :preferred_supply_id, "does not exist")

          _ ->
            add_error(changeset, :preferred_supply_id, "must belong to the same company")
        end
    end
  end
end
