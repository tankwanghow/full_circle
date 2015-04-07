class PurchaseOrder < ActiveRecord::Base
  belongs_to :supplier, class_name: "Account"
  has_many :details, :class_name => "PurchaseOrderDetail"

  include ValidateBelongsTo
  validate_belongs_to :supplier, :name1

  accepts_nested_attributes_for :details, allow_destroy: true

private

  def filter
    <<-SQL
      select po.doc_date, po.available_at, ac.name1, p.name1, pod.package_qty, 
             pk.name, pod.note, pod.quantity, p.unit, pod.unit_price
        from purchase_orders po 
       inner join purchase_order_details pod on po.id = pod.purchase_order_id
       inner join products p on p.id = pod.product_id
       inner join accounts ac on po.supplier_id = ac.id
       inner join product_packagings pp on pp.product_id = p.id
       inner join packagings pk on pk.id = pp.packaging_id and pod.product_packaging_id = pp.id
    SQL
  end

end