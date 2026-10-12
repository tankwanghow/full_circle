defmodule FullCircle.Accounting.Contact do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "contacts" do
    belongs_to :company, FullCircle.Sys.Company
    field :category, :string
    field :address1, :string
    field :address2, :string
    field :city, :string
    field :country, :string
    field :name, :string
    field :state, :string
    field :zipcode, :string
    field :reg_no, :string
    field :tax_id, :string
    field :email, :string
    field :phone, :string
    field :contact_info, :string
    field :descriptions, :string
    field :sst_id, :string
    field :gst_id, :string
    field :tou_id, :string
    field :misc_code, :string

    # Supplier bank details for bank payment files. Written only through
    # bank_changeset/2 (admin/manager); changeset/2 never casts them.
    field :bank_code, :string
    field :bank_account_no, :string
    field :bank_account_name, :string
    field :bank_details_changed_at, :utc_datetime

    has_many :invoices, FullCircle.Billing.Invoice

    # Concurrency guard, see FullCircle.StdInterface.changeset/5
    field :lock_version, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @bank_fields [:bank_code, :bank_account_no, :bank_account_name]

  def bank_changeset(contact, attrs) do
    contact
    |> cast(attrs, @bank_fields)
    |> update_change(:bank_account_no, &(&1 && String.replace(&1, ~r/\D/, "")))
    |> update_change(:bank_account_name, &(&1 && String.trim(&1)))
    |> validate_length(:bank_account_name, max: 120)
    |> validate_bank_details()
    |> stamp_bank_change()
  end

  defp validate_bank_details(cs) do
    values = Enum.map(@bank_fields, &get_field(cs, &1))

    cond do
      Enum.all?(values, &(&1 in [nil, ""])) ->
        cs

      Enum.any?(values, &(&1 in [nil, ""])) ->
        Enum.reduce(@bank_fields, cs, fn f, acc ->
          if get_field(acc, f) in [nil, ""],
            do: add_error(acc, f, gettext("required when bank details are filled")),
            else: acc
        end)

      true ->
        validate_account_length(cs)
    end
  end

  defp validate_account_length(cs) do
    case FullCircle.BankPayment.Banks.get(get_field(cs, :bank_code)) do
      nil ->
        add_error(cs, :bank_code, gettext("not in list"))

      bank ->
        if String.length(get_field(cs, :bank_account_no)) in bank.lengths,
          do: cs,
          else:
            add_error(
              cs,
              :bank_account_no,
              gettext("must be %{lengths} digits for %{bank}",
                lengths: Enum.join(bank.lengths, "/"),
                bank: bank.name
              )
            )
    end
  end

  defp stamp_bank_change(cs) do
    if Enum.any?(@bank_fields, &Map.has_key?(cs.changes, &1)),
      do:
        put_change(cs, :bank_details_changed_at, DateTime.utc_now() |> DateTime.truncate(:second)),
      else: cs
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
      :tax_id,
      :email,
      :phone,
      :contact_info,
      :descriptions,
      :category,
      :company_id,
      :gst_id,
      :sst_id,
      :tou_id
    ])
    |> validate_required([:name, :company_id])
    |> validate_length(:descriptions, max: 230)
    |> validate_length(:name, max: 230)
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
