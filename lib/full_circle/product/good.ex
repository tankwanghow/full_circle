defmodule FullCircle.Product.Good do
  use Ecto.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "goods" do
    field(:name, :string)
    field(:unit, :string)
    field(:descriptions, :string)

    belongs_to(:company, FullCircle.Sys.Company)

    belongs_to(:purchase_account, FullCircle.Accounting.Account, foreign_key: :purchase_account_id)

    belongs_to(:purchase_tax_code, FullCircle.Accounting.TaxCode,
      foreign_key: :purchase_tax_code_id
    )

    belongs_to(:sales_account, FullCircle.Accounting.Account, foreign_key: :sales_account_id)
    belongs_to(:sales_tax_code, FullCircle.Accounting.TaxCode, foreign_key: :sales_tax_code_id)

    has_many(:invoice_details, FullCircle.CustomerBilling.InvoiceDetail)
    has_many(:packagings, FullCircle.Product.Packaging, on_delete: :delete_all)

    field(:purchase_account_name, :string, virtual: true)
    field(:purchase_tax_code_name, :string, virtual: true)
    field(:sales_account_name, :string, virtual: true)
    field(:sales_tax_code_name, :string, virtual: true)
    field(:purchase_tax_rate, :decimal, virtual: true)
    field(:sales_tax_rate, :decimal, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(good, attrs) do
    good
    |> cast(attrs, [
      :name,
      :unit,
      :descriptions,
      :company_id,
      :purchase_account_name,
      :sales_account_name,
      :purchase_tax_code_name,
      :sales_tax_code_name,
      :purchase_account_id,
      :purchase_tax_code_id,
      :sales_account_id,
      :sales_tax_code_id,
      :purchase_tax_rate,
      :sales_tax_rate
    ])
    |> validate_required([
      :name,
      :unit,
      :company_id,
      :purchase_account_name,
      :sales_account_name,
      :purchase_tax_code_name,
      :sales_tax_code_name
    ])
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :goods_unique_name_in_company,
      message: gettext("has already been taken")
    )
    |> validate_id(:sales_account_name, :sales_account_id)
    |> validate_id(:purchase_account_name, :purchase_account_id)
    |> validate_id(:sales_tax_code_name, :sales_tax_code_id)
    |> validate_id(:purchase_tax_code_name, :purchase_tax_code_id)
    |> cast_assoc(:packagings)
    |> foreign_key_constraint(:name,
      name: :invoice_details_good_id_fkey,
      message: gettext("referenced by invoice details")
    )
  end
end
