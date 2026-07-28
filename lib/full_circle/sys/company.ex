defmodule FullCircle.Sys.Company do
  use FullCircle.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias FullCircle.Repo
  use Gettext, backend: FullCircleWeb.Gettext

  schema "companies" do
    field :address1, :string
    field :address2, :string
    field :city, :string
    field :country, :string
    field :name, :string
    field :state, :string
    field :zipcode, :string
    field :timezone, :string
    field :reg_no, :string
    field :email, :string
    field :tel, :string
    field :fax, :string
    field :descriptions, :string
    field :tax_id, :string
    field :gst_id, :string
    field :sst_id, :string
    field :tou_id, :string
    field :misc_code, :string
    field :closing_month, :integer
    field :closing_day, :integer
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @days_in_closing_month %{
    1 => 31,
    2 => 28,
    3 => 31,
    4 => 30,
    5 => 31,
    6 => 30,
    7 => 31,
    8 => 31,
    9 => 30,
    10 => 31,
    11 => 30,
    12 => 31
  }

  @doc """
  Highest day selectable as a closing day for `month`, or `nil` if the month is
  not 1..12.

  February stops at 28 rather than 29: the year-end boundary is rebuilt for an
  arbitrary year (`Reporting.prev_close_date/2` uses `Date.new!/3`), so a
  29 February closing day would raise in three years out of four.

  This is the one place the rule lives — the closing-day select and the test
  fixtures both read it from here.
  """
  def days_in_closing_month(month), do: Map.get(@days_in_closing_month, month)

  @doc "Selectable closing days for `month`; `[]` when the month is not 1..12."
  def closing_day_options(month) do
    case days_in_closing_month(month) do
      nil -> []
      max -> Enum.to_list(1..max)
    end
  end

  @doc false
  def changeset(company, attrs, user) do
    company
    |> cast(attrs, [
      :name,
      :address1,
      :address2,
      :city,
      :zipcode,
      :state,
      :country,
      :closing_month,
      :closing_day,
      :timezone,
      :reg_no,
      :email,
      :tel,
      :fax,
      :descriptions,
      :tax_id,
      :misc_code
    ])
    |> validate_required([
      :name,
      :country,
      :timezone,
      :closing_day,
      :closing_month
    ])
    |> validate_number(:closing_day,
      greater_than: 0,
      less_than: 32,
      message: gettext("must between 1 to 31")
    )
    |> validate_number(:closing_month,
      greater_than: 0,
      less_than: 13,
      message: gettext("must between 1 to 12")
    )
    |> validate_closing_day_in_month()
    |> validate_length(:descriptions, max: 230)
    |> validate_length(:name, max: 230)
    |> validate_inclusion(:country, FullCircle.Sys.countries(), message: gettext("not in list"))
    |> validate_inclusion(:timezone, Tzdata.zone_list(), message: gettext("not in list"))
    |> validate_unique_by_user(:name, user)
  end

  # The select is a UI-only guard and it goes stale: narrowing the month leaves
  # the previously chosen day out of the option list. Enforce the pair here so
  # the rule also holds for seeds, imports and console writes.
  defp validate_closing_day_in_month(changeset) do
    month = get_field(changeset, :closing_month)
    day = get_field(changeset, :closing_day)
    max = days_in_closing_month(month)

    if is_integer(day) and is_integer(max) and day > max do
      # Raw msgid, not gettext/1 — translate_error/1 interpolates from these opts
      # against the "errors" domain, so interpolating here would be too early.
      add_error(
        changeset,
        :closing_day,
        dgettext_noop("errors", "only 1 to %{max} in month %{month}"),
        max: max,
        month: month
      )
    else
      changeset
    end
  end

  def validate_unique_by_user(changeset, field, user) do
    {_, name} = fetch_field(changeset, field)
    {_, id} = fetch_field(changeset, :id)

    if Repo.exists?(company_name_by_user_query(name || "", id, user)) do
      add_error(changeset, field, gettext("has already been taken"))
    else
      changeset
    end
  end

  defp company_name_by_user_query(name, company_id, user) when is_nil(company_id) do
    from f in FullCircle.Sys.Company,
      join: fu in FullCircle.Sys.CompanyUser,
      on: f.id == fu.company_id,
      where: fu.user_id == ^user.id and f.name == ^name,
      select: f
  end

  defp company_name_by_user_query(name, company_id, user) do
    from f in FullCircle.Sys.Company,
      join: fu in FullCircle.Sys.CompanyUser,
      on: f.id == fu.company_id,
      where: fu.user_id == ^user.id and f.name == ^name and f.id != ^company_id,
      select: f
  end
end
