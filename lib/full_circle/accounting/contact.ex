defmodule FullCircle.Accounting.Contact do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "contacts" do
    belongs_to :company, FullCircle.Sys.Company
    field :address1, :string
    field :address2, :string
    field :city, :string
    field :country, :string
    field :name, :string
    field :state, :string
    field :zipcode, :string
    field :reg_no, :string
    field :email, :string
    field :contact_info, :string
    field :descriptions, :string

    has_many :invoices, FullCircle.Billing.Invoice

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [
      :name,
      :address1,
      :address2,
      :city,
      :zipcode,
      :state,
      :country,
      :reg_no,
      :email,
      :contact_info,
      :descriptions,
      :company_id
    ])
    |> validate_required([:name, :company_id])
    |> validate_inclusion(:country, FullCircle.Sys.countries(), message: gettext("not in list"))
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :contacts_unique_name_in_company,
      message: gettext("has already been taken")
    )
    |> foreign_key_constraint(:name,
      name: :invoices_contact_id_fkey,
      message: gettext("referenced by invoices")
    )
    |> foreign_key_constraint(:name,
      name: :pur_invoices_contact_id_fkey,
      message: gettext("referenced by pur_invoices")
    )
    |> foreign_key_constraint(:name,
      name: :transactions_contact_id_fkey,
      message: gettext("referenced by pur_invoices")
    )
  end
end
