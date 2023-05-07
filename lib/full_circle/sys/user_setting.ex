defmodule FullCircle.Sys.UserSetting do
  use Ecto.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "user_settings" do
    field :company_user_id, :integer
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

  def default_settings("invoice", cuid) do
    [
      %{
        page: "invoice",
        code: "goodamt-col",
        display_name: "Good Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoice",
        code: "taxamt-col",
        display_name: "Tax Amount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoice",
        code: "account-col",
        display_name: "Account",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoice",
        code: "taxrate-col",
        display_name: "Tax Rate",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      },
      %{
        page: "invoice",
        code: "discount-col",
        display_name: "Discount",
        values: %{"show" => "visible", "hide" => "hidden"},
        value: "show",
        company_user_id: cuid
      }
    ]
  end
end
