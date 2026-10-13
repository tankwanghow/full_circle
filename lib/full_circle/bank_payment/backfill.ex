defmodule FullCircle.BankPayment.Backfill do
  @moduledoc """
  One-off go-live job for bank payment files: creates the bank file formats and
  paying-account profiles, then fills supplier bank details from the account
  numbers clerks typed into Payment descriptions ("IBG (MBB 507116409616)",
  "TRANSFER RHB 20806100058823").

  Dry run by default: it reports and changes nothing. A real run writes through
  the normal audited paths (`BankPayment.save_format/4`, `save_profile/4`,
  `Accounting.save_contact_bank/4`) as the admin named, never overwrites bank
  details already on a contact, and is safe to run twice.

  Production (a release, no Mix):

      docker compose run --rm web /app/bin/full_circle eval \\
        'FullCircle.Release.bank_backfill("<company id>", "<admin email>", dry_run: true)'
  """
  import Ecto.Query, warn: false

  alias FullCircle.{Accounting, BankPayment, Repo}
  alias FullCircle.Accounting.{Account, Contact}
  alias FullCircle.BankPayment.{Banks, Profile}
  alias FullCircle.BillPay.Payment

  # Kim Poh Sitt Tat's paying accounts. `corporate_name: :company` fills the
  # RHB corporate name from the company; RHB's corporate_id comes later.
  @default_accounts [
    %{
      gl: "Rhb Bank 2-08025-0001399-9",
      format: "rhb_bulk_pay",
      our: "20802500013999",
      params: %{"corporate_name" => :company}
    },
    %{gl: "Public Bank 3126284617", format: "pbb_ecp_payment", our: "3126284617", params: %{}}
  ]

  # Owner's decision (2026-10-13): unclear accounts, or paid through an agent.
  @default_skip [
    "Federal Machinery And Industrial Supplies",
    "Song Hin Trading Company",
    "Leong Hup Agrobusiness Sdn Bhd",
    "Jabatan Pengangkutan Jalan Malaysia",
    "Liberty Insurance Berhad"
  ]

  # Abbreviation as clerks write it → BIC. Islamic arms can't be told apart
  # from the description, so the conventional bank is used.
  @abbreviations [
    {~r/\b(PIBB|PUBLIC\s*ISLAMIC)\b/i, "PIBEMYK1"},
    {~r/\b(PBB|PUBLIC\s*BANK|PBE)\b/i, "PBBEMYKL"},
    {~r/\b(MBB|MAYBANK|MBS|M2U)\b/i, "MBBEMYKL"},
    {~r/\bCIMB\b/i, "CIBBMYKL"},
    {~r/\bRHB\b/i, "RHBBMYKL"},
    {~r/\bOCBC\b/i, "OCBCMYKL"},
    {~r/\b(HLB|HLBB|HONG\s*LEONG)\b/i, "HLBBMYKL"},
    {~r/\b(AMB|AMBANK|AM\s*BANK)\b/i, "ARBKMYKL"},
    {~r/\bUOB\b/i, "UOVBMYKL"},
    {~r/\b(BIMB|BANK\s*ISLAM)\b/i, "BIMBMYKL"},
    {~r/\bBSN\b/i, "BSNAMYK1"},
    {~r/\bAFFIN\b/i, "PHBMMYKL"},
    {~r/\b(ALLIANCE|ABMB)\b/i, "MFBBMYKL"},
    {~r/\bAGRO/i, "AGOBMYKL"},
    {~r/\bMUAMALAT\b/i, "BMMBMYKL"},
    {~r/\b(RAKYAT|BKRM)\b/i, "BKRMMYKL"},
    {~r/\bHSBC\b/i, "HBMBMYKL"},
    {~r/\b(SCB|STANDARD\s*CHARTERED)\b/i, "SCBLMYKX"},
    {~r/\bBOC\b/i, "BKCHMYKL"},
    {~r/\bCITI/i, "CITIMYKL"},
    {~r/\bDEUTSCHE/i, "DEUTMYKL"}
  ]

  @account_number ~r/(?<![0-9])([0-9](?:[0-9\- ]{6,22})[0-9])(?![0-9])/

  def default_skip, do: @default_skip

  @doc """
  Options: `dry_run` (default true), `skip` (contact names, default the owner's
  five), `accounts` (default Kim Poh Sitt Tat's RHB and Public Bank accounts),
  `start_date` (profiles' start date, default company-local today).
  """
  def run(company_id, admin_email, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)

    with %FullCircle.Sys.Company{} = company <-
           Repo.get(FullCircle.Sys.Company, company_id) || {:error, "company not found"},
         {:ok, admin} <- find_admin(company, admin_email),
         {:ok, accounts} <-
           find_accounts(company, Keyword.get(opts, :accounts, @default_accounts)) do
      start_date = Keyword.get(opts, :start_date, BankPayment.today(company))
      formats = setup_formats(company, admin, accounts, dry_run)
      {profiles, warnings} = setup_profiles(company, admin, accounts, start_date, dry_run)

      details =
        import_details(company, admin, accounts, Keyword.get(opts, :skip, @default_skip), dry_run)

      {:ok,
       Map.merge(details, %{
         dry_run: dry_run,
         company: company.name,
         formats_created: formats,
         profiles_created: profiles,
         profile_warnings: warnings
       })}
    end
  end

  defp find_admin(company, email) do
    user = Repo.get_by(FullCircle.UserAccounts.User, email: email)

    if user && FullCircle.Authorization.user_role_in_company(user.id, company.id) == "admin",
      do: {:ok, user},
      else: {:error, "#{email} is not an admin of #{company.name}"}
  end

  defp find_accounts(company, specs) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
      case Repo.get_by(Account, company_id: company.id, name: spec.gl, account_type: "Bank") do
        nil -> {:halt, {:error, "no Bank GL account named #{spec.gl}"}}
        a -> {:cont, {:ok, acc ++ [Map.put(spec, :account, a)]}}
      end
    end)
  end

  # ── Formats and profiles ───────────────────────────

  defp setup_formats(company, admin, accounts, dry_run) do
    today = BankPayment.today(company)

    accounts
    |> Enum.map(& &1.format)
    |> Enum.uniq()
    |> Enum.reject(&BankPayment.effective_format(company.id, &1, today))
    |> Enum.sort()
    |> Enum.map(fn code ->
      unless dry_run do
        {:ok, t} = BankPayment.load_template(code)

        {:ok, _} =
          BankPayment.save_format(
            %{
              "code" => code,
              "name" => t["name"],
              "effective_from" => Date.to_iso8601(today),
              "spec" => t["spec"]
            },
            company,
            admin
          )
      end

      code
    end)
  end

  defp setup_profiles(company, admin, accounts, start_date, dry_run) do
    existing = BankPayment.list_profiles(company)

    created =
      for spec <- accounts, not Enum.any?(existing, &(&1.account_id == spec.account.id)) do
        unless dry_run do
          params =
            Map.new(spec.params, fn {k, v} ->
              {k, if(v == :company, do: company.name, else: v)}
            end)

          {:ok, _} =
            BankPayment.save_profile(
              %Profile{},
              %{
                "account_id" => spec.account.id,
                "format_code" => spec.format,
                "our_account_no" => spec.our,
                "start_date" => Date.to_iso8601(start_date),
                "params" => params
              },
              company,
              admin
            )
        end

        spec.gl
      end

    warnings =
      if dry_run,
        do: %{},
        else:
          Map.new(
            BankPayment.list_profiles(company),
            &{&1.account_name, BankPayment.profile_warnings(&1, company)}
          )

    {Enum.sort(created), warnings}
  end

  # ── Bank details from Payment descriptions ─────────

  defp import_details(company, admin, accounts, skip, dry_run) do
    candidates = candidates(company, Enum.map(accounts, & &1.account.id))

    {imported, skipped, kept, failed} =
      Enum.reduce(candidates, {[], [], [], []}, fn c, {imp, sk, kept, fl} ->
        contact = Repo.get!(Contact, c.contact_id)

        cond do
          contact.name in skip ->
            {imp, [contact.name | sk], kept, fl}

          contact.bank_code != nil ->
            {imp, sk, [contact.name | kept], fl}

          dry_run ->
            {[row(c) | imp], sk, kept, fl}

          true ->
            attrs = %{
              "bank_code" => c.bic,
              "bank_account_no" => c.no,
              "bank_account_name" => contact.name
            }

            case Accounting.save_contact_bank(contact, attrs, company, admin) do
              {:ok, _} -> {[row(c) | imp], sk, kept, fl}
              {:error, cs} -> {imp, sk, kept, [{contact.name, inspect(cs.errors)} | fl]}
            end
        end
      end)

    imported = Enum.sort_by(imported, &String.downcase(&1.contact))
    imported_names = MapSet.new(imported, & &1.contact)

    %{
      imported: imported,
      skipped: Enum.sort(skipped),
      kept_existing: Enum.sort(kept),
      failed: Enum.reverse(failed),
      ambiguous:
        for(
          c <- candidates,
          c.others != [],
          MapSet.member?(imported_names, c.contact),
          do: ambiguous(c)
        )
        |> Enum.sort_by(&String.downcase(&1.contact))
    }
  end

  defp row(c),
    do: %{contact: c.contact, bic: c.bic, bank: Banks.short_name(c.bic), account_no: c.no}

  defp ambiguous(c) do
    %{
      contact: c.contact,
      chosen: "#{Banks.short_name(c.bic)} #{c.no}",
      others:
        Enum.map(
          c.others,
          &"#{Banks.short_name(&1.bic)} #{&1.no} (#{&1.count}x, last #{&1.latest})"
        )
    }
  end

  @doc "Per supplier: the account to use plus the others seen, from Payments on `account_ids`."
  def candidates(company, account_ids) do
    from(p in Payment,
      join: c in assoc(p, :contact),
      where: p.company_id == ^company.id and p.funds_account_id in ^account_ids,
      select: %{contact_id: c.id, contact: c.name, date: p.payment_date, desc: p.descriptions}
    )
    |> Repo.all()
    |> Enum.flat_map(fn p ->
      case parse(p.desc) do
        nil -> []
        found -> [Map.merge(p, found)]
      end
    end)
    |> Enum.group_by(& &1.contact_id)
    |> Enum.map(fn {_id, uses} ->
      [best | others] =
        uses
        |> Enum.group_by(&{&1.bic, &1.no})
        |> Enum.map(fn {{bic, no}, l} ->
          %{
            bic: bic,
            no: no,
            count: length(l),
            latest: Enum.max(Enum.map(l, & &1.date), Date),
            len_ok: hd(l).len_ok
          }
        end)
        # A valid length first (short numbers are typos), then most recent, then most used.
        |> Enum.sort_by(&{&1.len_ok, Date.to_iso8601(&1.latest), &1.count}, :desc)

      %{
        contact_id: hd(uses).contact_id,
        contact: hd(uses).contact,
        bic: best.bic,
        no: best.no,
        len_ok: best.len_ok,
        others: others
      }
    end)
    |> Enum.filter(& &1.len_ok)
  end

  @doc "Bank and account number from a Payment description, or nil."
  def parse(nil), do: nil

  def parse(desc) do
    with {re, bic} <- Enum.find(@abbreviations, fn {re, _} -> Regex.match?(re, desc) end),
         [{start, _} | _] <- Regex.run(re, desc, return: :index),
         [_, raw] <- Regex.run(@account_number, binary_part(desc, start, byte_size(desc) - start)) do
      no = String.replace(raw, ~r/\D/, "")
      %{bic: bic, no: no, len_ok: String.length(no) in Banks.get(bic).lengths}
    else
      _ -> nil
    end
  end

  # ── Report ─────────────────────────────────────────

  @doc "Human-readable summary of a run, for the release console."
  def report(r) do
    verb = if r.dry_run, do: "would", else: "did"

    [
      if(r.dry_run,
        do: "DRY RUN — nothing was changed. Re-run with dry_run: false to apply.",
        else: "APPLIED."
      ),
      "Company: #{r.company}",
      "Formats: #{verb} create #{inspect(r.formats_created)}",
      "Profiles: #{verb} create #{inspect(r.profiles_created)}",
      for({name, w} <- r.profile_warnings, w != [], do: "  #{name}: #{inspect(w)}"),
      "Bank details: #{verb} import #{length(r.imported)}",
      Enum.map(r.imported, &"  #{&1.contact} | #{&1.bank} #{&1.account_no}"),
      "Skipped (owner's list): #{length(r.skipped)} #{inspect(r.skipped)}",
      "Kept (already had bank details): #{length(r.kept_existing)}",
      "More than one account seen (most recent valid one used): #{length(r.ambiguous)}",
      Enum.map(
        r.ambiguous,
        &"  #{&1.contact} | using #{&1.chosen} | also #{Enum.join(&1.others, "; ")}"
      ),
      "Failed: #{length(r.failed)}",
      Enum.map(r.failed, fn {n, e} -> "  #{n}: #{e}" end)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end
end
