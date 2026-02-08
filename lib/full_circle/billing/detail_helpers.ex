defmodule FullCircle.Billing.DetailHelpers do
  import Ecto.Changeset
  import FullCircle.Helpers

  def compute_struct_fields(doc, detail_key, amount_key, good_amount_key, tax_amount_key) do
    doc
    |> sum_struct_field_to(detail_key, :good_amount, good_amount_key)
    |> sum_struct_field_to(detail_key, :tax_amount, tax_amount_key)
    |> sum_struct_field_to(detail_key, :amount, amount_key)
  end

  def compute_fields(changeset, detail_key, amount_key, good_amount_key, tax_amount_key) do
    changeset =
      changeset
      |> sum_field_to(detail_key, :good_amount, good_amount_key)
      |> sum_field_to(detail_key, :tax_amount, tax_amount_key)
      |> sum_field_to(detail_key, :amount, amount_key)
      |> sum_field_to(detail_key, :quantity, :sum_qty)

    cond do
      Decimal.to_float(fetch_field!(changeset, amount_key)) <= 0.0 ->
        add_unique_error(changeset, amount_key, Gettext.gettext(FullCircleWeb.Gettext, "must be > 0"))

      Decimal.eq?(fetch_field!(changeset, :sum_qty), 0) ->
        add_unique_error(changeset, amount_key, Gettext.gettext(FullCircleWeb.Gettext, "need detail"))

      true ->
        changeset
    end
  end

  def compute_detail_fields(changeset) do
    unit_multi = fetch_field!(changeset, :unit_multiplier)
    pack_qty = fetch_field!(changeset, :package_qty)
    price = fetch_field!(changeset, :unit_price)
    disc = fetch_field!(changeset, :discount)
    rate = fetch_field!(changeset, :tax_rate)

    qty =
      if Decimal.gt?(unit_multi, 0) do
        Decimal.mult(pack_qty, unit_multi)
      else
        fetch_field!(changeset, :quantity)
      end

    good_amount = Decimal.mult(qty, price) |> Decimal.add(disc) |> Decimal.round(2)
    tax_amount = Decimal.mult(good_amount, rate) |> Decimal.round(2)
    amount = Decimal.add(good_amount, tax_amount)

    changeset
    |> put_change(:good_amount, good_amount)
    |> put_change(:tax_amount, tax_amount)
    |> put_change(:amount, amount)
    |> put_change(:quantity, qty)
  end

  def maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  def maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end
end
