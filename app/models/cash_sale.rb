class CashSale < ActiveRecord::Base
  include SharedHelpers
  belongs_to :customer, class_name: "Account"
  has_many :particulars, as: :doc, class_name: "CashSaleParticular"
  has_many :transactions, as: :doc
  has_many :details, order: 'product_id', class_name: "CashSaleDetail"
  has_many :cheques, as: :db_doc

  validates_presence_of :customer_name1, :doc_date

  acts_as_taggable
  acts_as_taggable_on :loader, :unloader

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
  accepts_nested_attributes_for :cheques, allow_destroy: true

  include ValidateBelongsTo
  validate_belongs_to :customer, :name1

  include ValidateTransactionsBalance

  include Searchable
  searchable doc_date: :doc_date, doc_amount: :sales_amount, doc_posted: :posted,
             content: [:id, :customer_name1, :details_audit_string, :sales_amount,
                       :note, :particulars_audit_string, :cheques_audit_string,
                       :tag_list, :loader_list, :unloader_list, :posted]

  simple_audit username_method: :username do |r|
     {
      doc_date: r.doc_date.to_s,
      customer: r.customer_name1,
      details: r.details_audit_string,
      note: r.note,
      particulars: r.particulars_audit_string,
      cheques: r.cheques_audit_string,
      tag_list: r.tag_list,
      loader_list: r.loader_list,
      unloader_list: r.unloader_list,
      posted: r.posted,
      sales_amount: r.sales_amount
     }
  end

  include AuditString
  audit_string :details, :particulars, :cheques

  include SumAttributes
  sum_of :details, "goods_total", "goods"
  sum_of :details, "discount", "discount"
  sum_of :details, "gst", "details_gst"
  sum_of :details, "in_gst_total", "in_gst"

  sum_of :particulars, "in_gst_total", "particulars_in_gst"
  sum_of :particulars, "ex_gst_total", "particulars_ex_gst"
  sum_of :particulars, "gst", "particulars_gst"

  sum_of :cheques, "amount"

  def self.new_like id
    like = find(id)
    a = new(like.attributes.merge(tag_list: like.tag_list, loader_list: like.loader_list, unloader_list: like.unloader_list))
    a.details.build
    a
  end

  def sales_amount
    in_gst_amount + particulars_in_gst_amount
  end

  def gst_amount
    details_gst_amount + particulars_gst_amount
  end

private

  def build_transactions
    transactions.where(old_data: false).destroy_all
    set_cheques_account
    build_cash_n_pd_chq_transaction
    build_details_transactions
    build_particulars_transactions
    validates_transactions_balance
  end

  def set_cheques_account
    cheques.select { |t| !t.marked_for_destruction? }.each do |t|
      t.db_ac = customer
    end
  end

  def build_details_transactions
    details.select { |t| t.in_gst_total != 0 and !t.marked_for_destruction? }.each do |t|
      t.cash_sale = self
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

  def build_cash_n_pd_chq_transaction
    cash_amount = sales_amount - cheques_amount

    cash_in_hand_note = [customer_name1, product_summary, particular_summary].join(' ').truncate(70)

    if cash_amount < 0
      cash_in_hand_note = ['Cheque change cash', cash_in_hand_note].join(' ').truncate(70)
    end

    if cash_amount != 0
      transactions.build(
        doc: self,
        transaction_date: doc_date,
        account: Account.find_by_name1('Cash In Hand'),
        note: cash_in_hand_note,
        amount: cash_amount,
        user: User.current)
    end

    cheques.select { |t| !t.marked_for_destruction? }.each do |t|
      transactions.build(
        doc: self,
        transaction_date: doc_date,
        account: Account.find_by_name1('Post Dated Cheques'),
        note: [customer_name1, t.bank, t.chq_no].join(' '),
        amount: t.amount,
        user: User.current)
    end
  end

end
