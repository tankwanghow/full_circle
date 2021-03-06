class Deposit < ActiveRecord::Base
  belongs_to :bank, class_name: "Account"
  has_many :transactions, as: :doc
  has_many :cheques, as: :cr_doc, autosave: true

  validates_presence_of :bank_name1, :doc_date
  validates_numericality_of :cash_amount, greater_than: -0.0001

  before_save :build_transactions

  include ValidateBelongsTo
  validate_belongs_to :bank, :name1

  include ValidateTransactionsBalance

  include Searchable
  searchable doc_date: :doc_date, doc_amount: :deposit_amount,
             content: [:id, :bank_name1, :cash_amount,
                       :cheques_audit_string]

  simple_audit username_method: :username do |r|
     {
      doc_date: r.doc_date.to_s,
      bank: r.bank_name1,
      cash: r.cash_amount,
      cheques: r.cheques_audit_string
     }
  end

  def deposit_amount
    cash_amount + cheques_amount
  end

  def cheques_audit_string
    cheques.select { |t| t.cr_doc != nil }.
    map{ |t| t.simple_audit_string }.join(' ')
  end

  def cheques_amount
    cheques.select { |t| t.cr_doc != nil }.
    inject(0) { |sum, p| sum + p.amount }
  end

  def cheques_attributes= vals
    vals.each do |k, v|
      chq = Cheque.find(v['id'].to_i)
      if chq
        if v['_destroy'] == '1'
          chq.cr_doc = nil
          chq.cr_ac = nil
          chq.save
        else
          chq.cr_doc = self
          chq.cr_ac = bank
          cheques << chq
        end
      end
    end
  end

private

  def build_transactions
    transactions.where(old_data: false).destroy_all
    build_cash_transaction if cash_amount > 0
    build_pd_chq_transaction if cheques_amount > 0
    validates_transactions_balance
  end

  def build_cash_transaction
    transactions.build(
      doc: self,
      transaction_date: doc_date,
      account: Account.find_by_name1('Cash In Hand'),
      note: 'To ' + bank_name1,
      amount: -cash_amount,
      user: User.current)

    transactions.build(
      doc: self,
      transaction_date: doc_date,
      account: bank,
      note: 'By Cash',
      amount: cash_amount,
      user: User.current)
  end

  def build_pd_chq_transaction
    cheques.select { |t| t.cr_doc != nil }.each do |t|
      transactions.build(
        doc: self,
        transaction_date: doc_date,
        account: Account.find_by_name1('Post Dated Cheques'),
        note: "To #{bank_name1}, " + [t.bank, t.chq_no, t.city, t.due_date].join(' '),
        amount: -t.amount,
        user: User.current)

      transactions.build(
        doc: self,
        transaction_date: doc_date,
        account: bank,
        note: [t.bank, t.chq_no].join(' '),
        amount: t.amount,
        user: User.current)
    end
  end

end
