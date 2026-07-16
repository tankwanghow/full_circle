defmodule FullCircle.Trading.SalesPosition do
  use FullCircle.Schema
  import Ecto.Changeset

  alias FullCircle.Repo
  alias FullCircle.Trading.SupplyPosition

  @statuses ~w(draft open fulfilled cancelled)

  schema "trading_sales_positions" do
    field :title, :string
    field :reference_no, :string
    field :period, :string
    field :quantity, :decimal
    field :unit_price, :decimal
    field :status, :string, default: "draft"
    field :notes, :string
    field :fulfilled_note, :string

    field :customer_name, :string, virtual: true
    field :good_name, :string, virtual: true
    field :preferred_supply_title, :string, virtual: true
    field :parent_title, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :customer, FullCircle.Accounting.Contact
    belongs_to :good, FullCircle.Product.Good
    belongs_to :parent, __MODULE__
    belongs_to :preferred_supply, SupplyPosition

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :title,
      :reference_no,
      :period,
      :quantity,
      :unit_price,
      :status,
      :notes,
      :fulfilled_note,
      :company_id,
      :customer_id,
      :good_id,
      :parent_id,
      :preferred_supply_id,
      :customer_name,
      :good_name,
      :preferred_supply_title,
      :parent_title
    ])
    |> validate_required([:quantity, :company_id, :customer_id, :good_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:quantity, greater_than: 0)
    |> validate_parent_same_company()
    |> validate_preferred_supply_same_company()
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:customer_id)
    |> foreign_key_constraint(:good_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:preferred_supply_id)
  end

  defp validate_parent_same_company(changeset) do
    parent_id = get_field(changeset, :parent_id)
    company_id = get_field(changeset, :company_id)

    cond do
      is_nil(parent_id) or is_nil(company_id) ->
        changeset

      true ->
        case Repo.get(FullCircle.Trading.SalesPosition, parent_id) do
          %{company_id: ^company_id} ->
            changeset

          nil ->
            add_error(changeset, :parent_id, "does not exist")

          _ ->
            add_error(changeset, :parent_id, "must belong to the same company")
        end
    end
  end

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
