defmodule FullCircle.Accounting.TaxCode do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "tax_codes" do
    field :code, :string
    field :rate, :decimal
    field :tax_type, :string
    field :descriptions, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :account, FullCircle.Accounting.Account
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
    |> validate_inclusion(:tax_type, FullCircle.Accounting.tax_types(),
      message: gettext("not in list")
    )
    |> unsafe_validate_unique([:code, :company_id], FullCircle.Repo,
      message: gettext("code already in company")
    )
    |> unique_constraint(:code,
      name: :tax_codes_unique_code_in_company,
      message: gettext("code already in company")
    )
    |> validate_id(:account_name, :account_id)
    |> foreign_key_constraint(:code,
      name: :invoice_details_tax_code_id_fkey,
      message: gettext("referenced by invoice details")
    )
    |> foreign_key_constraint(:code,
      name: :pur_invoice_details_tax_code_id_fkey,
      message: gettext("referenced by pur_invoice details")
    )
    |> foreign_key_constraint(:code,
      name: :goods_purchase_tax_code_id_fkey,
      message: gettext("referenced by goods")
    )
    |> foreign_key_constraint(:code,
      name: :goods_sales_tax_code_id_fkey,
      message: gettext("referenced by goods")
    )
  end
end
