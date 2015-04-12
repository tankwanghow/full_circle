class SalesOrder < ActiveRecord::Base
  belongs_to :customer, class_name: "Account"
  has_many :details, :class_name => "SalesOrderDetail"

  include ValidateBelongsTo
  validate_belongs_to :customer, :name1

  accepts_nested_attributes_for :details, allow_destroy: true

  include Searchable
  searchable doc_date: :doc_date,
             content: [:id, :customer_name1, :details_audit_string, :deliver_at, :note]

  include AuditString
  audit_string :details

  simple_audit username_method: :username do |r|
     {
      doc_date: r.doc_date.to_s,
      deliver_at: r.deliver_at.to_s,
      customer: r.customer_name1,
      details: r.details_audit_string,
      note: r.note
     }
  end

  def self.query term=nil, date=nil, fulfilled=nil
    find_by_sql sql(term, date, fulfilled)
  end

private

  def self.sql term, date, fulfilled
    "select so.id, sod.id as sales_order_detail_id, so.doc_date, so.deliver_at, 
            ac.name1 as customer_name, p.name1 as product_name, sod.package_qty,
            pk.name as packaging_name, sod.note as detail_note, sod.quantity, p.unit, sod.unit_price
       from sales_orders so
      inner join sales_order_details sod on so.id = sod.sales_order_id
      inner join products p on p.id = sod.product_id
      inner join accounts ac on so.customer_id = ac.id
      inner join product_packagings pp on pp.product_id = p.id
      inner join packagings pk on pk.id = pp.packaging_id and sod.product_packaging_id = pp.id
      where 1 = 1 " + terms_condition(term) + date_condition(date) + fulfilled_condition(fulfilled)
  end

  def self.terms_condition term=nil
    if term
      t = term.split(' ').join('%')
      "and concat(ac.name1, p.name1, sod.note) ilike '%#{t}%'"
    else
      ''
    end
  end

  def self.date_condition date=nil
    if date
      "and (doc_date >= '#{date.to_date.to_s(:db)}' or deliver_at >= '#{date.to_date.to_s(:db)}')"
    else
      ''
    end
  end

  def self.fulfilled_condition fulfilled
    if fulfilled == "true"
      "and fulfilled = 't'"
    else
      "and fulfilled = 'f'"
    end
  end

end
