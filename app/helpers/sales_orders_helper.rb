module SalesOrdersHelper
  def render_sales_order_details_fields builder, xies_name
    render 'share/nested_fields', f: builder, xies_name: xies_name, field: 'sales_order_detail',
            headers: [['Product', 'span10'], ['Package', 'span5'], ['Pack', 'span3'], ['Note', 'span10'],
                      ['Quantity', 'span5'], ['Balance', 'span5'], ['Unit', 'span3'], ['Price', 'span4'], ['F', 'span1']],
            text: 'Add Detail'
  end

  def manage_loading_orders_link order_detail_id
    od = SalesOrderDetail.find(order_detail_id)
    if !od.has_loading_orders?
      label_tag dom_id(od), "No Arrangement Yet !!"
    else
      link_to_loading_orders_count(od)
    end
  end

  def link_to_loading_orders_count order_detail
    link_to "#{order_detail.loading_orders_count} Loading Orders", '#', class: 'label label-warning'
  end

  def sales_order_product_info order_detail
    label_tag dom_id(order_detail), order_detail["product_name"] + ' ' +
              (order_detail["package_qty"].to_i == 0 ? '' : order_detail["package_qty"].to_i.to_s) + ' (' +
              order_detail["packaging_name"] + ') ' + 
              number_with_precision(order_detail["quantity"], precision: 2, delimiter: ',') +
              order_detail["unit"] + ' ' + order_detail["detail_note"]
  end
end
