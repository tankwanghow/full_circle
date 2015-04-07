class SalesOrder < ActiveRecord::Base
  belongs_to :customer, class_name: "Account"
  has_many :details, :class_name => "SalesOrderDetail"
  
  include ValidateBelongsTo
  validate_belongs_to :customer, :name1

  accepts_nested_attributes_for :details, allow_destroy: true

  def self.query
    find_by_sql filter
  end

  def self.filter
    <<-SQL
      select so.id, so.doc_date, so.deliver_at, ac.name1 as customer_name, p.name1 as product_name, sod.package_qty, 
             pk.name as packaging_name, sod.note as detail_note, sod.quantity, p.unit, sod.unit_price
        from sales_orders so 
       inner join sales_order_details sod on so.id = sod.sales_order_id
       inner join products p on p.id = sod.product_id
       inner join accounts ac on so.customer_id = ac.id
       inner join product_packagings pp on pp.product_id = p.id
       inner join packagings pk on pk.id = pp.packaging_id and sod.product_packaging_id = pp.id
    SQL
  end

end