defmodule FullCircle.HR.PaySlip do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "pay_slips" do
    field(:slip_no, :string)
    field(:slip_date, :date)
    field(:pay_month, :integer)
    field(:pay_year, :integer)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:funds_account, FullCircle.Accounting.Account)

    has_many(:additions, FullCircle.HR.SalaryNote, on_delete: :delete_all)
    has_many(:bonuses, FullCircle.HR.SalaryNote, on_delete: :delete_all)
    has_many(:deductions, FullCircle.HR.SalaryNote, on_delete: :delete_all)
    has_many(:contributions, FullCircle.HR.SalaryNote, on_delete: :delete_all)
    has_many(:leaves, FullCircle.HR.SalaryNote, on_delete: :nothing)
    has_many(:advances, FullCircle.HR.Advance, on_delete: :nothing)

    field(:employee_name, :string, virtual: true)
    field(:funds_account_name, :string, virtual: true)
    field(:addition_amount, :decimal, virtual: true, default: 0)
    field(:fixed_wage_amount, :decimal, virtual: true, default: 0)
    field(:deduction_amount, :decimal, virtual: true, default: 0)
    field(:advance_amount, :decimal, virtual: true, default: 0)
    field(:bonus_amount, :decimal, virtual: true, default: 0)
    field(:pay_slip_amount, :decimal, virtual: true, default: 0)

    timestamps(type: :utc_datetime)
  end

  @doc false
  defp std_changeset(slip, attrs, opts \\ []) do
    # New payslips enforce ±15 days from today; post-create payment edits only
    # require the date to stay near the pay period (validate_pay_month_year).
    date_window? = Keyword.get(opts, :date_window, true)

    cs =
      slip
      |> cast(attrs, [
        :slip_no,
        :slip_date,
        :pay_month,
        :pay_year,
        :employee_name,
        :employee_id,
        :funds_account_name,
        :funds_account_id,
        :company_id
      ])
      |> validate_required([
        :slip_no,
        :slip_date,
        :pay_month,
        :pay_year,
        :employee_name,
        :funds_account_name,
        :company_id
      ])
      |> validate_id(:employee_name, :employee_id)
      |> validate_id(:funds_account_name, :funds_account_id)

    cs =
      if date_window? do
        cs
        |> validate_date(:slip_date, days_before: 15)
        |> validate_date(:slip_date, days_after: 15)
      else
        cs
      end

    cs
    |> validate_pay_month_year()
    |> unsafe_validate_unique([:slip_no, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:slip_no,
      name: :pay_slips_unique_slip_no_in_company,
      message: gettext("has already been taken")
    )
    |> unsafe_validate_unique([:pay_month, :pay_year, :employee_id, :company_id], FullCircle.Repo,
      message: gettext("same pay period exists")
    )
    |> unique_constraint(:pay_month,
      name: :pay_slips_unique_employee_id_pay_month_pay_year_in_company,
      message: gettext("same pay period exists")
    )
    |> cast_assoc(:additions, with: &FullCircle.HR.SalaryNote.changeset_on_payslip/2)
    |> cast_assoc(:bonuses, with: &FullCircle.HR.SalaryNote.changeset_on_payslip/2)
    |> cast_assoc(:deductions, with: &FullCircle.HR.SalaryNote.changeset_on_payslip/2)
    |> cast_assoc(:contributions, with: &FullCircle.HR.SalaryNote.changeset_on_payslip/2)
    |> cast_assoc(:leaves, with: &FullCircle.HR.SalaryNote.changeset_on_payslip/2)
    |> cast_assoc(:advances, with: &FullCircle.HR.Advance.changeset_on_payslip/2)
  end

  def changeset_no_compute(slip, attrs) do
    slip |> std_changeset(attrs)
  end

  def changeset(slip, attrs) do
    slip |> std_changeset(attrs) |> compute_fields()
  end

  @doc """
  Form changeset for an existing pay slip (view + edit pay date / funds account).
  Skips the ±15-day-from-today window so older slips in an open period remain editable.
  """
  def changeset_for_form(slip, attrs) do
    slip |> std_changeset(attrs, date_window: false) |> compute_fields()
  end

  @doc """
  Validates only pay date and payment account for post-create amendments.
  """
  def changeset_payment_meta(slip, attrs) do
    slip
    |> cast(attrs, [:slip_date, :funds_account_name, :funds_account_id])
    |> validate_required([:slip_date, :funds_account_name])
    |> validate_id(:funds_account_name, :funds_account_id)
    |> validate_pay_month_year()
  end

  def compute_struct_fields(sn) do
    sn =
      sn
      |> sum_struct_field_to(:additions, :amount, :addition_amount)
      |> sum_struct_field_to(:deductions, :amount, :deduction_amount)
      |> sum_struct_field_to(:advances, :amount, :advance_amount)
      |> sum_struct_field_to(:bonuses, :amount, :bonus_amount)
      |> compute_struct_fixed_wage_amount()

    Map.replace!(
      sn,
      :pay_slip_amount,
      sn.addition_amount
      |> Decimal.add(sn.bonus_amount)
      |> Decimal.sub(sn.advance_amount)
      |> Decimal.sub(sn.deduction_amount)
    )
  end

  def compute_fields(changeset) do
    changeset =
      changeset
      |> sum_field_to(:additions, :amount, :addition_amount)
      |> sum_field_to(:deductions, :amount, :deduction_amount)
      |> sum_field_to(:advances, :amount, :advance_amount)
      |> sum_field_to(:bonuses, :amount, :bonus_amount)
      |> compute_fixed_wage_amount()

    changeset =
      force_change(
        changeset,
        :pay_slip_amount,
        fetch_field!(changeset, :addition_amount)
        |> Decimal.add(fetch_field!(changeset, :bonus_amount))
        |> Decimal.sub(fetch_field!(changeset, :deduction_amount))
        |> Decimal.sub(fetch_field!(changeset, :advance_amount))
      )

    if Decimal.lt?(fetch_field!(changeset, :pay_slip_amount), 0) do
      add_unique_error(changeset, :pay_slip_amount, gettext("must be +ve"))
    else
      changeset |> clear_error(:pay_slip_amount)
    end
  end

  # fixed_wage_amount is the FixedWages subset of :additions — the HRD Corp
  # levy base — while addition_amount stays the full wage sum.
  defp compute_struct_fixed_wage_amount(sn) do
    sum =
      if is_struct(sn.additions, Ecto.Association.NotLoaded) do
        Decimal.new("0")
      else
        sn.additions
        |> Enum.filter(fn n -> n.salary_type_type == "FixedWages" end)
        |> Enum.reduce(Decimal.new("0"), fn n, acc -> Decimal.add(acc, n.amount) end)
      end

    Map.replace!(sn, :fixed_wage_amount, Decimal.round(sum, 2))
  end

  defp compute_fixed_wage_amount(changeset) do
    sum =
      changeset
      |> get_change_or_data(:additions)
      |> Enum.reduce(Decimal.new("0"), fn x, acc ->
        func =
          if is_struct(x, Ecto.Changeset) do
            &fetch_field!/2
          else
            &Map.fetch!/2
          end

        if func.(x, :salary_type_type) == "FixedWages" and !func.(x, :delete) do
          Decimal.add(acc, func.(x, :amount))
        else
          acc
        end
      end)

    put_change(changeset, :fixed_wage_amount, Decimal.round(sum, 2))
  end

  defp validate_pay_month_year(cs) do
    slip_date = fetch_field!(cs, :slip_date)

    if !is_nil(slip_date) do
      mth = fetch_field!(cs, :pay_month) || Timex.today().year
      yr = fetch_field!(cs, :pay_year) || Timex.today().month
      day = Timex.days_in_month(yr, mth)

      if abs(Timex.diff(Date.new!(yr, mth, day), slip_date, :days)) > 31 do
        cs
        |> add_unique_error(:pay_month, gettext("invalid"))
        |> add_unique_error(:pay_year, gettext("invalid"))
      else
        cs
      end
    else
      cs
    end
  end
end
