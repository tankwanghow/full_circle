defmodule FullCircle.Billing do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.Billing.{Invoice, InvoiceDetail, PurInvoice, PurInvoiceDetail}
  alias FullCircle.Accounting.{Contact, Account, Transaction, TaxCode}
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.StdInterface
  alias FullCircle.{Sys, Accounting}
  alias Ecto.Multi

  def get_print_invoice!(id, company, user) do
    Repo.one(
      from inv in Invoice,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: invd in InvoiceDetail,
        on: invd.invoice_id == inv.id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id == ^id,
        preload: [invoice_details: ^print_invoice_details()],
        group_by: [inv.id, inv.invoice_no, inv.descriptions, cont.name],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          invoice_tax_amount:
            sum(
              fragment(
                "round((?*?+?)*?, 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.tax_rate
              )
            ),
          invoice_good_amount:
            sum(
              fragment(
                "round(((?*?)+?), 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount
              )
            ),
          invoice_amount:
            sum(
              fragment(
                "round(((?*?)+?)+(((?*?)+?)*?), 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.tax_rate
              )
            )
        }
    )
  end

  defp print_invoice_details do
    from invd in InvoiceDetail,
      join: good in Good,
      on: good.id == invd.good_id,
      join: ac in Account,
      on: invd.account_id == ac.id,
      join: tc in TaxCode,
      on: tc.id == invd.tax_code_id,
      left_join: pkg in Packaging,
      on: pkg.id == invd.package_id,
      order_by: invd.id,
      select: invd,
      select_merge: %{
        unit: good.unit,
        good_name: good.name,
        account_name: ac.name,
        package_name: pkg.name,
        tax_code: tc.code,
        tax_rate: tc.rate * 100,
        tax_amount:
          fragment(
            "round(((?*?)+?)*?, 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.tax_rate
          ),
        good_amount:
          fragment(
            "round(((?*?)+?), 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount
          ),
        amount:
          fragment(
            "round(((?*?)+?)+(((?*?)+?)*?), 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.tax_rate
          )
      }
  end

  def get_invoice!(id, company, user) do
    Repo.one(
      from inv in Invoice,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: invd in InvoiceDetail,
        on: invd.invoice_id == inv.id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id == ^id,
        preload: [invoice_details: ^invoice_details()],
        group_by: [inv.id, inv.invoice_no, inv.descriptions, cont.name, inv.tags, cont.id],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          contact_id: cont.id,
          invoice_tax_amount:
            sum(
              fragment(
                "round((?*?+?)*?, 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.tax_rate
              )
            ),
          invoice_good_amount:
            sum(
              fragment(
                "round(((?*?)+?), 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount
              )
            ),
          invoice_amount:
            sum(
              fragment(
                "round(((?*?)+?)+(((?*?)+?)*?), 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.tax_rate
              )
            )
        }
    )
  end

  defp invoice_details do
    from invd in InvoiceDetail,
      join: good in Good,
      on: good.id == invd.good_id,
      join: ac in Account,
      on: invd.account_id == ac.id,
      join: tc in TaxCode,
      on: tc.id == invd.tax_code_id,
      left_join: pkg in Packaging,
      on: pkg.id == invd.package_id,
      order_by: invd.id,
      select: invd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        account_name: ac.name,
        unit_multiplier: pkg.unit_multiplier,
        tax_rate: invd.tax_rate,
        tax_code_name: tc.code,
        tax_amount:
          fragment(
            "round(((?*?)+?)*?, 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.tax_rate
          ),
        good_amount:
          fragment(
            "round((?*?)+?, 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount
          ),
        amount:
          fragment(
            "round(((?*?)+?)+(((?*?)+?)*?), 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.tax_rate
          )
      }
  end

  def invoice_index_query("", "", "", com, user, page: page, per_page: per_page) do
    from(inv in subquery(invoice_query(com, user, page: page, per_page: per_page)),
      order_by: [desc: inv.updated_at]
    )
    |> Repo.all()
  end

  def invoice_index_query("", date_from, "", com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.invoice_date >= ^date_from,
        order_by: inv.invoice_date
    )
  end

  def invoice_index_query("", "", due_date_from, com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.due_date >= ^due_date_from,
        order_by: inv.due_date
    )
  end

  def invoice_index_query(terms, "", "", com, user, page: page, per_page: per_page) do
    from(inv in subquery(invoice_query(com, user, page: page, per_page: per_page)),
      order_by: ^similarity_order([:invoice_no, :contact_name, :goods, :descriptions], terms)
    )
    |> Repo.all()
  end

  def invoice_index_query(terms, date_from, "", com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.invoice_date >= ^date_from,
        order_by: ^similarity_order([:invoice_no, :contact_name, :goods, :descriptions], terms),
        order_by: inv.invoice_date
    )
  end

  def invoice_index_query(terms, "", due_date_from, com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.due_date >= ^due_date_from,
        order_by: ^similarity_order([:invoice_no, :contact_name, :goods, :descriptions], terms),
        order_by: inv.due_date
    )
  end

  def invoice_index_query(terms, date_from, due_date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    Repo.all(
      from inv in subquery(invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.invoice_date >= ^date_from,
        where: inv.due_date >= ^due_date_from,
        order_by: ^similarity_order([:invoice_no, :contact_name, :goods, :descriptions], terms),
        order_by: [inv.invoice_date, inv.due_date]
    )
  end

  def get_invoice_by_id_index_component_field!(id, com, user) do
    from(i in subquery(invoice_query(com, user, page: 1, per_page: 10)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp invoice_query(company, user, page: page, per_page: per_page) do
    from inv in Invoice,
      as: :invoices,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == inv.company_id,
      join: cont in Contact,
      on: cont.id == inv.contact_id,
      join: invd in InvoiceDetail,
      as: :invoice_details,
      on: invd.invoice_id == inv.id,
      join: good in Good,
      as: :goods,
      on: good.id == invd.good_id,
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      order_by: [desc: inv.updated_at],
      select: %{
        id: inv.id,
        invoice_no: inv.invoice_no,
        descriptions: inv.descriptions,
        tags: inv.tags,
        invoice_date: inv.invoice_date,
        due_date: inv.due_date,
        inserted_at: inv.inserted_at,
        updated_at: inv.updated_at,
        contact_id: cont.id
      },
      select_merge: %{
        contact_name: cont.name,
        invoice_amount:
          sum(
            fragment(
              "round(((?*?)+?)+(((?*?)+?)*?), 2)",
              invd.quantity,
              invd.unit_price,
              invd.discount,
              invd.quantity,
              invd.unit_price,
              invd.discount,
              invd.tax_rate
            )
          )
      },
      select_merge: %{
        goods:
          fragment(
            "string_agg(DISTINCT ? || COALESCE('(' || ? || ')', ''), ', ')",
            good.name,
            invd.descriptions
          )
      },
      group_by: [inv.id, cont.name, inv.descriptions, inv.invoice_date, inv.due_date, cont.id]
  end

  def create_invoice(attrs, com, user) do
    case can?(user, :create_invoice, com) do
      true ->
        Multi.new()
        |> create_invoice_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_invoice_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    invoice_name = :create_invoice

    multi
    |> get_gapless_doc_id(gapless_name, "invoices", "INV", com)
    |> Multi.insert(
      invoice_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)
        StdInterface.changeset(Invoice, %Invoice{}, Map.merge(attrs, %{"invoice_no" => doc}), com)
      end
    )
    |> Sys.insert_log_for(invoice_name, attrs, com, user)
    |> create_invoice_transactions(invoice_name, com, user)
  end

  defp create_invoice_transactions(multi, name, com, user) do
    ac_rec_id = FullCircle.Accounting.get_account_by_name!("Account Receivables", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => invoice} ->
      Invoice.fill_computed_field(invoice)

      Enum.each(invoice.invoice_details, fn x ->
        if Decimal.gt?(x.good_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "invoices",
            doc_id: invoice.id,
            doc_no: invoice.invoice_no,
            doc_date: invoice.invoice_date,
            account_id: x.account_id,
            company_id: com.id,
            amount: Decimal.negate(x.good_amount),
            particulars: "Sold #{x.good_name} to #{invoice.contact_name}"
          })
        end

        if Decimal.gt?(x.tax_amount, 0) do
          tax_ac_id = Accounting.get_tax_code!(x.tax_code_id, com, user).account_id

          repo.insert!(%Transaction{
            doc_type: "invoices",
            doc_id: invoice.id,
            doc_no: invoice.invoice_no,
            doc_date: invoice.invoice_date,
            account_id: tax_ac_id,
            company_id: com.id,
            amount: Decimal.negate(x.tax_amount),
            particulars: "#{x.tax_code_name} on #{x.good_name}"
          })
        end
      end)

      cont_part =
        Enum.map(invoice.invoice_details, fn x -> String.slice(x.good_name, 0..14) end)
        |> Enum.join(", ")

      repo.insert!(%Transaction{
        doc_type: "invoices",
        doc_id: invoice.id,
        doc_no: invoice.invoice_no,
        doc_date: invoice.invoice_date,
        contact_id: invoice.contact_id,
        account_id: ac_rec_id,
        company_id: com.id,
        amount: invoice.invoice_amount,
        particulars: invoice.contact_name,
        contact_particulars: cont_part
      })

      {:ok, nil}
    end)
  end

  def update_invoice(%Invoice{} = invoice, attrs, com, user) do
    case can?(user, :update_invoice, com) do
      true ->
        Multi.new()
        |> update_invoice_multi(invoice, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_invoice_multi(multi, invoice, attrs, com, user) do
    invoice_name = :update_invoice

    multi
    |> Multi.update(invoice_name, StdInterface.changeset(Invoice, invoice, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "invoices",
        where: txn.doc_no == ^invoice.invoice_no
      )
    )
    |> Sys.insert_log_for(invoice_name, attrs, com, user)
    |> create_invoice_transactions(invoice_name, com, user)
  end

  ########
  # Purchase Invocie
  ########

  def get_pur_invoice!(id, company, user) do
    Repo.one(
      from inv in PurInvoice,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: invd in PurInvoiceDetail,
        on: invd.pur_invoice_id == inv.id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id == ^id,
        preload: [pur_invoice_details: ^pur_invoice_details()],
        group_by: [
          inv.id,
          inv.pur_invoice_no,
          inv.supplier_invoice_no,
          inv.descriptions,
          cont.name,
          inv.tags,
          cont.id
        ],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          contact_id: cont.id,
          pur_invoice_tax_amount:
            sum(
              fragment(
                "round((?*?+?)*?, 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.tax_rate
              )
            ),
          pur_invoice_good_amount:
            sum(
              fragment(
                "round(((?*?)+?), 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount
              )
            ),
          pur_invoice_amount:
            sum(
              fragment(
                "round(((?*?)+?)+(((?*?)+?)*?), 2)",
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.quantity,
                invd.unit_price,
                invd.discount,
                invd.tax_rate
              )
            )
        }
    )
  end

  defp pur_invoice_details do
    from invd in PurInvoiceDetail,
      join: good in Good,
      on: good.id == invd.good_id,
      join: ac in Account,
      on: invd.account_id == ac.id,
      join: tc in TaxCode,
      on: tc.id == invd.tax_code_id,
      left_join: pkg in Packaging,
      on: pkg.id == invd.package_id,
      order_by: invd.id,
      select: invd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        account_name: ac.name,
        unit_multiplier: pkg.unit_multiplier,
        tax_rate: invd.tax_rate,
        tax_code_name: tc.code,
        tax_amount:
          fragment(
            "round(((?*?)+?)*?, 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.tax_rate
          ),
        good_amount:
          fragment(
            "round((?*?)+?, 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount
          ),
        amount:
          fragment(
            "round(((?*?)+?)+(((?*?)+?)*?), 2)",
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.quantity,
            invd.unit_price,
            invd.discount,
            invd.tax_rate
          )
      }
  end

  def pur_invoice_index_query("", "", "", com, user, page: page, per_page: per_page) do
    from(inv in subquery(pur_invoice_query(com, user, page: page, per_page: per_page)),
      order_by: [desc: inv.updated_at]
    )
    |> Repo.all()
  end

  def pur_invoice_index_query("", date_from, "", com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(pur_invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.pur_invoice_date >= ^date_from,
        order_by: inv.pur_invoice_date
    )
  end

  def pur_invoice_index_query("", "", due_date_from, com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(pur_invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.due_date >= ^due_date_from,
        order_by: inv.due_date
    )
  end

  def pur_invoice_index_query(terms, "", "", com, user, page: page, per_page: per_page) do
    from(inv in subquery(pur_invoice_query(com, user, page: page, per_page: per_page)),
      order_by:
        ^similarity_order(
          [:pur_invoice_no, :supplier_invoice_no, :contact_name, :goods, :descriptions],
          terms
        )
    )
    |> Repo.all()
  end

  def pur_invoice_index_query(terms, date_from, "", com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(pur_invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.pur_invoice_date >= ^date_from,
        order_by:
          ^similarity_order(
            [:pur_invoice_no, :supplier_invoice_no, :contact_name, :goods, :descriptions],
            terms
          ),
        order_by: inv.pur_invoice_date
    )
  end

  def pur_invoice_index_query(terms, "", due_date_from, com, user, page: page, per_page: per_page) do
    Repo.all(
      from inv in subquery(pur_invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.due_date >= ^due_date_from,
        order_by:
          ^similarity_order(
            [:pur_invoice_no, :supplier_invoice_no, :contact_name, :goods, :descriptions],
            terms
          ),
        order_by: inv.due_date
    )
  end

  def pur_invoice_index_query(terms, date_from, due_date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    Repo.all(
      from inv in subquery(pur_invoice_query(com, user, page: page, per_page: per_page)),
        where: inv.pur_invoice_date >= ^date_from,
        where: inv.due_date >= ^due_date_from,
        order_by:
          ^similarity_order(
            [:pur_invoice_no, :supplier_invoice_no, :contact_name, :goods, :descriptions],
            terms
          ),
        order_by: [inv.pur_invoice_date, inv.due_date]
    )
  end

  def get_pur_invoice_by_id_index_component_field!(id, com, user) do
    from(i in subquery(pur_invoice_query(com, user, page: 1, per_page: 10)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp pur_invoice_query(company, user, page: page, per_page: per_page) do
    from inv in PurInvoice,
      as: :pur_invoices,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == inv.company_id,
      join: cont in Contact,
      on: cont.id == inv.contact_id,
      join: invd in PurInvoiceDetail,
      as: :pur_invoice_details,
      on: invd.pur_invoice_id == inv.id,
      join: good in Good,
      as: :goods,
      on: good.id == invd.good_id,
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      order_by: [desc: inv.updated_at],
      select: %{
        id: inv.id,
        pur_invoice_no: inv.pur_invoice_no,
        supplier_invoice_no: inv.supplier_invoice_no,
        descriptions: inv.descriptions,
        tags: inv.tags,
        pur_invoice_date: inv.pur_invoice_date,
        due_date: inv.due_date,
        inserted_at: inv.inserted_at,
        updated_at: inv.updated_at,
        contact_id: cont.id
      },
      select_merge: %{
        contact_name: cont.name,
        pur_invoice_amount:
          sum(
            fragment(
              "round(((?*?)+?)+(((?*?)+?)*?), 2)",
              invd.quantity,
              invd.unit_price,
              invd.discount,
              invd.quantity,
              invd.unit_price,
              invd.discount,
              invd.tax_rate
            )
          )
      },
      select_merge: %{
        goods:
          fragment(
            "string_agg(DISTINCT ? || COALESCE('(' || ? || ')', ''), ', ')",
            good.name,
            invd.descriptions
          )
      },
      group_by: [inv.id, cont.name, inv.descriptions, inv.pur_invoice_date, inv.due_date, cont.id]
  end

  def create_pur_invoice(attrs, com, user) do
    case can?(user, :create_pur_invoice, com) do
      true ->
        Multi.new()
        |> create_pur_invoice_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_pur_invoice_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    pur_invoice_name = :create_pur_invoice

    multi
    |> get_gapless_doc_id(gapless_name, "pur_invoices", "PINV", com)
    |> Multi.insert(
      pur_invoice_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          PurInvoice,
          %PurInvoice{},
          Map.merge(attrs, %{"pur_invoice_no" => doc}),
          com
        )
      end
    )
    |> Sys.insert_log_for(pur_invoice_name, attrs, com, user)
    |> create_pur_invoice_transactions(pur_invoice_name, com, user)
  end

  defp create_pur_invoice_transactions(multi, name, com, user) do
    ac_rec_id = FullCircle.Accounting.get_account_by_name!("Account Payables", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => pur_invoice} ->
      PurInvoice.fill_computed_field(pur_invoice)

      Enum.each(pur_invoice.pur_invoice_details, fn x ->
        if Decimal.gt?(x.good_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "pur_invoices",
            doc_id: pur_invoice.id,
            doc_no: pur_invoice.pur_invoice_no,
            doc_date: pur_invoice.pur_invoice_date,
            account_id: x.account_id,
            company_id: com.id,
            amount: x.good_amount,
            particulars: "Purchase #{x.good_name} from #{pur_invoice.contact_name}"
          })
        end

        if Decimal.gt?(x.tax_amount, 0) do
          tax_ac_id = Accounting.get_tax_code!(x.tax_code_id, com, user).account_id

          repo.insert!(%Transaction{
            doc_type: "pur_invoices",
            doc_id: pur_invoice.id,
            doc_no: pur_invoice.pur_invoice_no,
            doc_date: pur_invoice.pur_invoice_date,
            account_id: tax_ac_id,
            company_id: com.id,
            amount: x.tax_amount,
            particulars: "#{x.tax_code_name} on #{x.good_name}"
          })
        end
      end)

      cont_part =
        Enum.map(pur_invoice.pur_invoice_details, fn x -> String.slice(x.good_name, 0..14) end)
        |> Enum.join(", ")

      repo.insert!(%Transaction{
        doc_type: "pur_invoices",
        doc_id: pur_invoice.id,
        doc_no: pur_invoice.pur_invoice_no,
        doc_date: pur_invoice.pur_invoice_date,
        contact_id: pur_invoice.contact_id,
        account_id: ac_rec_id,
        company_id: com.id,
        amount: Decimal.negate(pur_invoice.pur_invoice_amount),
        particulars: pur_invoice.contact_name,
        contact_particulars: cont_part
      })

      {:ok, nil}
    end)
  end

  def update_pur_invoice(%PurInvoice{} = pur_invoice, attrs, com, user) do
    case can?(user, :update_pur_invoice, com) do
      true ->
        Multi.new()
        |> update_pur_invoice_multi(pur_invoice, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_pur_invoice_multi(multi, pur_invoice, attrs, com, user) do
    pur_invoice_name = :update_pur_invoice

    multi
    |> Multi.update(pur_invoice_name, StdInterface.changeset(PurInvoice, pur_invoice, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "pur_invoices",
        where: txn.doc_no == ^pur_invoice.pur_invoice_no
      )
    )
    |> Sys.insert_log_for(pur_invoice_name, attrs, com, user)
    |> create_pur_invoice_transactions(pur_invoice_name, com, user)
  end
end
