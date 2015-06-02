class SalesOrderDetail < ActiveRecord::Base
  belongs_to :sales_order
  belongs_to :product
  belongs_to :product_packaging
  has_many :arrangements

  validates_presence_of :product_name1, :unit
  validates_numericality_of :quantity, greater_than: 0

  include ValidateBelongsTo
  validate_belongs_to :product, :name1

  def arranged
    arrangements.where('load_quantity = 0')
  end

  def loaded
    arrangements.where('load_quantity > 0')
  end

  def delivered
    arrangements.where('deliver_quantity > 0')
  end

  def simple_audit_string
    [ product.name1, packaging_name, note, quantity, unit_price, fulfilled ].join ' '
  end

  def unit
    product.unit if product
  end

  def balance
    quantity - arrangements.sum(:deliver_quantity)
  end

  def packaging_name
    product_packaging.pack_qty_name if product_packaging
  end

  def packaging_name= val
    if !val.blank?
      pid = ProductPackaging.find_product_package(product_id, val).try(:id)
      if pid
        self.product_packaging_id = pid
      else
        errors.add 'packaging_name', 'not found!'
      end
    else
      self.product_packaging_id = nil
    end
  end

  def self.query term=nil, date=nil, fulfilled=nil
    find_by_sql sql(term, date, fulfilled)
  end

private

  def self.sql term, date, fulfilled
    "select sod.id, so.id as sales_order_id, so.doc_date, so.deliver_at,
            ac.name1 as customer_name, p.name1 as product_name, sod.package_qty,
            pk.name as packaging_name, sod.note as detail_note, sod.quantity, p.unit as unit, sod.unit_price
       from sales_order_details sod
      inner join sales_orders so on so.id = sod.sales_order_id
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
