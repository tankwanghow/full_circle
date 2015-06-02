class Arrangement < ActiveRecord::Base
  belongs_to :sales_order_detail
  belongs_to :purchase_order_detail
  belongs_to :loading_order
  belongs_to :invoice_detail
  belongs_to :pur_invoice_detail

  def unit
    sales_order_detail.try(:unit)
  end

  def transporter_info
    loading_order.transporter.name1.first(20) + ' ' + loading_order.lorry_no
  end

  def supply_info
    if purchase_order_detail
      purchase_order_detail.supplier.name1.first(20)
    else
      "match supplier..."
    end
  end

  def loading_info
    if load_quantity > 0
      load_date.to_s + " " + load_quantity.to_s + unit
    else
      "enter loading info..."
    end
  end

  def delivery_info
    if deliver_quantity > 0
      deliver_date.to_s + " " + deliver_quantity.to_s + unit
    else
      "enter delivery info..."
    end
  end

  def pur_invoice_info
    pur_invoice_detail.pur_invoice.reference_no if pur_invoice_detail
  end

  def invoice_info
    invoice_detail.invoice.id if invoice_detail
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
