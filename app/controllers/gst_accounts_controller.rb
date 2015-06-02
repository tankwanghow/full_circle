class GstAccountsController < ApplicationController

  def index
    store_param :gst_accounts
    session[:gst_accounts][:month] ||= Date.current.month - 1
    session[:gst_accounts][:year] ||= Date.current.year
    @date = "#{session[:gst_accounts][:year]}-#{session[:gst_accounts][:month]}-01".to_date.end_of_month
    start_date = @date.end_of_month.advance(days: -(@date.end_of_month.day - 1))
    end_date   = @date.end_of_month
    @accounts = Account.gst_accounts
    @gst_control_account = @accounts.select { |t| t.name1 =~ /Control/ }.first
    @gst_expense_account = @accounts.select { |t| t.name1 =~ /Expense/ }.first

    @scn  = gst_debit_and_credit_note_sum 'credit_note', 'GST for Supply', start_date, end_date
    @sdn  = gst_debit_and_credit_note_sum 'debit_note', 'GST for Supply', start_date, end_date
    @cs   = gst_supply_and_acqusition_sum 'cash_sale', 'GST for Supply', start_date, end_date
    @iv   = gst_supply_and_acqusition_sum 'invoice', 'GST for Supply', start_date, end_date

    @pcn  = gst_debit_and_credit_note_sum 'credit_note', 'GST for Purchase', start_date, end_date
    @pdn  = gst_debit_and_credit_note_sum 'debit_note', 'GST for Purchase', start_date, end_date
    @piv  = gst_supply_and_acqusition_sum 'pur_invoice', 'GST for Purchase', start_date, end_date
  end

  def create
    gsi = Account.find params[:gst_control_id].to_i
    aci = Account.find params[:account_id].to_i
    balance = params[:balance].to_d
    date = "#{session[:gst_accounts][:year]}-#{session[:gst_accounts][:month]}-01".to_date.end_of_month
    j = Journal.new(doc_date: date)
    if balance < 0
      aci_balance = balance.abs
      gsi_balance = -balance.abs
    else
      aci_balance = -balance.abs
      gsi_balance = balance.abs
    end
    j.transactions.build(account_id: aci.id, note: "Transfer to #{gsi.name1}", amount: aci_balance)
    j.transactions.build(account_id: gsi.id, note: "Transfer from #{aci.name1}", amount: gsi_balance)
    j.save
    redirect_to gst_accounts_path
  end

private

  def gst_supply_and_acqusition_sum doc, tax_type, start_date, end_date
    p = Account.find_by_sql [
      "SELECT SUM((docd.quantity * docd.unit_price) + docd.discount) as amount, 
              SUM(((docd.quantity * docd.unit_price) + docd.discount) * tx.rate / 100) as gst
         FROM #{doc}s doc
        INNER JOIN #{doc}_details docd
           ON docd.#{doc}_id = doc.id
        INNER JOIN tax_codes tx
           ON docd.tax_code_id = tx.id
          AND tx.tax_type = '#{tax_type}'
          AND tx.rate > 0
        INNER JOIN products p
           ON p.id = docd.product_id
        WHERE doc.doc_date >= ?
          AND doc.doc_date <= ?
          AND docd.quantity * docd.unit_price > 0", start_date, end_date]

    k = Account.find_by_sql [
      "SELECT SUM(docd.quantity * docd.unit_price) as amount, 
              SUM(docd.quantity * docd.unit_price * tx.rate / 100) as gst
         FROM #{doc}s doc
        INNER JOIN particulars docd
           ON docd.doc_id = doc.id
          AND docd.doc_type = '#{doc.classify}'
        INNER JOIN tax_codes tx
           ON docd.tax_code_id = tx.id
          AND tx.tax_type = '#{tax_type}'
          AND tx.rate > 0
        INNER JOIN particular_types p
           ON p.id = docd.particular_type_id
        WHERE doc.doc_date >= ?
          AND doc.doc_date <= ?
          AND docd.quantity * docd.unit_price > 0", start_date, end_date]
    { amount: p[0].amount.to_f.round(2) + k[0].amount.to_f.round(2), gst: p[0].gst.to_f.round(2) + k[0].gst.to_f.round(2) }
  end

  def gst_debit_and_credit_note_sum doc, tax_type, start_date, end_date
    k = Account.find_by_sql [
      "SELECT SUM(docd.quantity * docd.unit_price) as amount, 
              SUM(docd.quantity * docd.unit_price * tx.rate / 100) as gst
         FROM #{doc}s doc
        INNER JOIN particulars docd
           ON docd.doc_id = doc.id
          AND docd.doc_type = '#{doc.classify}'
        INNER JOIN tax_codes tx
           ON docd.tax_code_id = tx.id
          AND tx.tax_type = '#{tax_type}'
          AND tx.rate > 0
        INNER JOIN particular_types p
           ON p.id = docd.particular_type_id
        WHERE doc.doc_date >= ?
          AND doc.doc_date <= ?
          AND docd.quantity * docd.unit_price > 0", start_date, end_date]
    { amount: k[0].amount.to_f.round(2), gst: k[0].gst.to_f.round(2) }
  end

end
