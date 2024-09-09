defmodule FullCircle.Accounting.Account do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "accounts" do
    belongs_to :company, FullCircle.Sys.Company
    field :descriptions, :string
    field :account_type, :string
    field :name, :string

    has_many :sales_goods, FullCircle.Product.Good, foreign_key: :sales_account_id
    has_many :purchase_goods, FullCircle.Product.Good, foreign_key: :purchase_account_id
    has_many :invoice_details, FullCircle.Billing.InvoiceDetail

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:company_id, :account_type, :name, :descriptions])
    |> validate_required([:company_id, :account_type, :name])
    |> validate_length(:descriptions, max: 230)
    |> validate_length(:name, max: 230)
    |> validate_inclusion(:account_type, FullCircle.Accounting.account_types(),
      message: gettext("not in list")
    )
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :accounts_unique_name_in_company,
      message: gettext("has already been taken")
    )
    |> foreign_key_constraint(:name,
      name: :invoice_details_account_id_fkey,
      message: gettext("referenced by invoice details")
    )
    |> foreign_key_constraint(:name,
      name: :pur_invoice_details_account_id_fkey,
      message: gettext("referenced by pur_invoice details")
    )
    |> foreign_key_constraint(:name,
      name: :goods_purchase_account_id_fkey,
      message: gettext("referenced by goods")
    )
    |> foreign_key_constraint(:name,
      name: :goods_sales_account_id_fkey,
      message: gettext("referenced by goods")
    )
    |> foreign_key_constraint(:name,
      name: :transactions_account_id_fkey,
      message: gettext("referenced by transactions")
    )
  end
end
