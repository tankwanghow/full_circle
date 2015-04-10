class PurchaseOrder < ActiveRecord::Base
  belongs_to :supplier, class_name: "Account"
  has_many :details, :class_name => "PurchaseOrderDetail"

  include ValidateBelongsTo
  validate_belongs_to :supplier, :name1

  accepts_nested_attributes_for :details, allow_destroy: true
  
  include Searchable
  searchable doc_date: :doc_date, 
             content: [:id, :supplier_name1, :details_audit_string, :available_at, :note]

  include AuditString
  audit_string :details

  simple_audit username_method: :username do |r|
     {
      doc_date: r.doc_date.to_s,
      deliver_at: r.available_at.to_s,
      customer: r.supplier_name1,
      details: r.details_audit_string,
      note: r.note
     }
  end

  def self.query term=nil, date=nil, fulfilled=nil
    find_by_sql sql(term, date, fulfilled)
  end

private

  def self.sql term, date, fulfilled
    "select po.id, pod.id as purchase_order_detail_id, po.doc_date, po.available_at, 
            ac.name1 as supplier_name, p.name1 as product_name, pod.package_qty, 
            pk.name as packaging_name, pod.note as detail_note, p.unit, pod.unit_price,
            pod.quantity - (select COALESCE(sum(ar.load_quantity),0) from arrangements ar where ar.purchase_order_detail_id = pod.id) as balance
       from purchase_orders po 
      inner join purchase_order_details pod on po.id = pod.purchase_order_id
      inner join products p on p.id = pod.product_id
      inner join accounts ac on po.supplier_id = ac.id
      inner join product_packagings pp on pp.product_id = p.id
      inner join packagings pk on pk.id = pp.packaging_id and pod.product_packaging_id = pp.id
      where 1 = 1 " + terms_condition(term) + date_condition(date) + fulfilled_condition(fulfilled)
  end

  def self.terms_condition term=nil
    if term
      t = term.split(' ').join('%')
      "and concat(ac.name1, p.name1, pod.note) ilike '%#{t}%'"
    else
      ''
    end
  end

  def self.date_condition date=nil
    if date
      "and (doc_date >= '#{date.to_date.to_s(:db)}' or available_at  >= '#{date.to_date.to_s(:db)}')"
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