class PurInvoice < ActiveRecord::Base
  include SharedHelpers
  belongs_to :supplier, class_name: "Account"
  has_many :particulars, as: :doc, class_name: "PurInvoiceParticular"
  has_many :transactions, as: :doc
  has_many :details, order: 'product_id', class_name: "PurInvoiceDetail"

  validates_presence_of :credit_terms, :supplier_name1, :doc_date, :reference_no

  before_save do |r|
    raise "Cannot update a posted document" if !can_save?(Date.today, r.doc_date)
    if !r.posted or (r.posted and r.changes[:posted] == [false, true])
      build_transactions
    else
      raise "Cannot update a posted document"
    end
  end

  accepts_nested_attributes_for :details, allow_destroy: true
  accepts_nested_attributes_for :particulars, allow_destroy: true

  include ValidateBelongsTo
  validate_belongs_to :supplier, :name1

  acts_as_taggable
  acts_as_taggable_on :loader, :unloader

  include ValidateTransactionsBalance

  include Searchable
  searchable doc_date: :doc_date, doc_amount: :invoice_amount, doc_posted: :posted,
             content: [:id, :supplier_name1, :reference_no, :credit_terms, :details_audit_string, :invoice_amount,
                       :note, :particulars_audit_string, :tag_list, :loader_list, :unloader_list, :posted]

  simple_audit username_method: :username do |r|
     {
      doc_date: r.doc_date.to_s,
      customer: r.supplier_name1,
      reference_no: r.reference_no,
      credit_terms: r.credit_terms,
      details: r.details_audit_string,
      note: r.note,
      particulars: r.particulars_audit_string,
      tag_list: r.tag_list,
      loader_list: r.loader_list,
      unloader_list: r.unloader_list,
      posted: r.posted,
      invoice_amount: r.invoice_amount
     }
  end

  include AuditString
  audit_string :particulars, :details

  include SumAttributes
  sum_of :particulars, "in_gst_total"
  sum_of :details, "in_gst_total"

  def invoice_amount
    particulars_amount + details_amount
  end

  def matchers
    transactions.where(account_id: supplier_id).first.matchers
  end

private

  def build_transactions
    transactions.where(old_data: false).destroy_all
    build_supplier_transaction
    build_details_transactions
    build_particulars_transactions
    validates_transactions_balance
  end

  def build_details_transactions
    details.select { |t| t.in_gst_total != 0 and !t.marked_for_destruction? }.each do |t|
      t.pur_invoice = self
      transactions << t.transactions
    end
  end

  def build_particulars_transactions
    particulars.select{ |t| !t.marked_for_destruction? }.each do |t|
      t.doc = self
      transactions << t.transactions
    end
  end

  def product_summary
    details.select{ |t| !t.marked_for_destruction? }.map { |t| t.product.name1 }.uniq.join(', ')
  end

  def particular_summary
    particulars.select{ |t| !t.marked_for_destruction? }.map { |t| t.particular_type.name }.uniq.join(', ')
  end

  def build_supplier_transaction
    transactions.build(
      doc: self,
      transaction_date: doc_date,
      terms: credit_terms,
      account: supplier,
      note: (product_summary + particular_summary).truncate(70),
      amount: -invoice_amount,
      user: User.current
    )
  end
end
