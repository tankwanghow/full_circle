defmodule FullCircle.Sys.UserSetting do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "user_settings" do
    field :company_user_id, :binary_id
    field :page, :string
    field :code, :string
    field :display_name, :string
    field :values, :map
    field :value, :string
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:code, :values, :company_user_id, :display_name])
    |> unsafe_validate_unique([:company_user_id, :code, :page], FullCircle.Repo,
      message: gettext("page and code already in setting")
    )
    |> validate_required([:page, :code, :values, :value, :company_user_id, :display_name])
  end

  def default_settings("Invoice", cuid) do
    [
      %{
        page: "Invoice",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Invoice",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Invoice",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Invoice",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Invoice",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end

  def default_settings("Payment", cuid) do
    [
      %{
        page: "Payment",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Payment",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Payment",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Payment",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Payment",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end

  def default_settings("Receipt", cuid) do
    [
      %{
        page: "Receipt",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Receipt",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Receipt",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Receipt",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "Receipt",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end

  def default_settings("PurInvoice", cuid) do
    [
      %{
        page: "PurInvoice",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "PurInvoice",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "PurInvoice",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "PurInvoice",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "PurInvoice",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end
end
