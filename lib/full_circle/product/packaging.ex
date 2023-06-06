defmodule FullCircle.Product.Packaging do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "packagings" do
    field(:name, :string)
    field(:unit_multiplier, :decimal, default: 0)
    field(:cost_per_package, :decimal, default: 0)

    belongs_to :good, FullCircle.Product.Good

    has_many :invoice_details, FullCircle.Billing.InvoiceDetail, foreign_key: :package_id

    field(:delete, :boolean, virtual: true, default: false)
    field(:temp_id, :string, virtual: true)
  end

  @doc false
  def changeset(packaging, attrs) do
    packaging
    |> cast(attrs, [
      :name,
      :unit_multiplier,
      :cost_per_package,
      :delete
    ])
    |> validate_required([
      :name,
      :unit_multiplier,
      :cost_per_package
    ])
    |> unsafe_validate_unique([:name, :good_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :packagings_unique_name_in_goods,
      message: gettext("has already been taken")
    )
    |> foreign_key_constraint(:name,
      name: :invoice_details_package_id_fkey,
      message: gettext("referenced by invoice details")
    )
    |> foreign_key_constraint(:name,
      name: :pur_invoice_details_package_id_fkey,
      message: gettext("referenced by pur_invoice details")
    )
    |> maybe_mark_for_deletion()
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  defp maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end
end
