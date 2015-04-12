class Arrangement < ActiveRecord::Base
  belongs_to :sales_order_detail
  belongs_to :purchase_order_detail
  belongs_to :loading_order
  belongs_to :invoice_detail
  belongs_to :pur_invoice_detail

  def unit
    sales_order_detail.try(:unit)
  end

  def order_info
    if sales_order_detail
      sod = sales_order_detail
      sod.sales_order.customer_name1.first(15) + ' ' +
      sod.balance.to_s + " " + sod.unit+ " "+ sod.product_name1 +
      (sod.package_qty.to_i == 0 ? '' : sod.package_qty.to_i.to_s) + ' (' +
      sod.packaging_name + ')'
    end
  end

  def pur_order_info
    if purchase_order_detail
      pod = purchase_order_detail
      pod.purchase_order.supplier_name1.first(15)+ '' +
      pod.balance.to_s + " " + pod.unit + ' ' + pod.product_name1 + ' ' +
      (pod.package_qty.to_i == 0 ? '' : pod.package_qty.to_i.to_s) + ' (' +
      pod.packaging_name + ')'
    end
  end
end
