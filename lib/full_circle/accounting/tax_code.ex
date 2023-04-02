defmodule FullCircle.Accounting.TaxCode do
  use Ecto.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "tax_codes" do
    field :code, :string
    field :rate, :decimal
    field :tax_type, :string
    field :descriptions, :string

    field :company_id, :integer
    field :account_id, :integer
    field :account_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(tax_code, attrs) do
    tax_code
    |> cast(attrs, [
      :code,
      :tax_type,
      :rate,
      :descriptions,
      :company_id,
      :account_id,
      :account_name
    ])
    |> validate_required([:code, :tax_type, :rate, :account_name, :company_id, :account_id])
    |> unsafe_validate_unique([:code, :company_id], FullCircle.Repo,
      message: gettext("code already in company")
    )
    |> validate_id(:account_name, :account_id)
    # |> foreign_key_constraint(:code,
    #   name: :goods_sales_tax_code_id_fkey,
    #   message: gettext("referenced by goods")
    # )
    # |> foreign_key_constraint(:code,
    #   name: :goods_purchase_tax_code_id_fkey,
    #   message: gettext("referenced by goods")
    # )
    # |> foreign_key_constraint(:code,
    #   name: :invoice_details_tax_code_id_fkey,
    #   message: gettext("referenced by invoice details")
    # )
  end
end
