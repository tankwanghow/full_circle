module LoadingOrdersHelper
  def render_loading_order_details_fields builder, xies_name
    render 'share/nested_fields', f: builder, xies_name: xies_name, field: 'arrangement',
            headers: [['Sales Info', 'span10'], ['Purchase Info', 'span10'], ['Load Date', 'span5'], ['Load Qty', 'span3'],
                      ['Deliver Date', 'span5'], ['Deliver Qty', 'span3'], ['Unit', 'span2'], ['Note', 'span8']],
            text: 'Add Detail'

  end

  def sales_order_detail_info sodid
    sod = SalesOrderDetail.find sodid
    sod.sales_order.customer_name1 + ' ordered ' + sod.product_name1 + ' ' +
    (sod.package_qty.to_i == 0 ? '' : sod.package_qty.to_i.to_s) + ' (' +
    sod.packaging_name + ') ' +
    number_with_precision(sod.balance, precision: 2, delimiter: ',') + " " +
    sod.unit
  end

  def matching_purchase_orders sodid
    sod = SalesOrderDetail.find sodid
    term = sod.product.name1 + " " + sod.note
    date = sod.sales_order.deliver_at
    PurchaseOrder.query term, date
  end
end
