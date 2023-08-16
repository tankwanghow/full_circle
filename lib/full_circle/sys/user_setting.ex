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

  def default_settings("invoices", cuid) do
    [
      %{
        page: "invoices",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoices",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoices",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoices",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoices",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end

  def default_settings("payments", cuid) do
    [
      %{
        page: "payments",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "payments",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "payments",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "payments",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "payments",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end

  def default_settings("receipts", cuid) do
    [
      %{
        page: "receipts",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "receipts",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "receipts",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "receipts",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "receipts",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end

  def default_settings("pur_invoices", cuid) do
    [
      %{
        page: "pur_invoices",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "pur_invoices",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "pur_invoices",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "pur_invoices",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "pur_invoices",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end
end
