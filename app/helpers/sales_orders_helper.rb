module SalesOrdersHelper
  def render_sales_order_details_fields builder, xies_name
    render 'share/nested_fields', f: builder, xies_name: xies_name, field: 'sales_order_detail',
            headers: [['Product', 'span10'], ['Package', 'span5'], ['Pack', 'span3'], ['Note', 'span10'], 
                      ['Quantity', 'span5'], ['Balance', 'span5'], ['Unit', 'span3'], ['Price', 'span4'], ['F', 'span1']],
            text: 'Add Detail'
  end

  def manage_arrangements_link order_detail_id
    od = SalesOrderDetail.find(order_detail_id)
    if !od.has_arrangements?
      link_to_add_arrangement order_detail_id
    else
      link_to_arrangement_count(od) + ' ' + link_to_add_arrangement(order_detail_id)
    end
  end

  def link_to_add_arrangement order_detail_id
    link_to "+", purchase_orders_select_path(sod: order_detail_id), class: 'label label-success'
  end

  def link_to_arrangement_count order_detail
    link_to "#{order_detail.arrangements_count} Arrangements", arrangements_list_path(order_detail), class: 'label label-warning'
  end

  def sales_order_product_info order_detail
    label_tag dom_id(order_detail), order_detail.product_name + ' ' + 
              (order_detail.package_qty.to_i == 0 ? '' : order_detail.package_qty.to_i.to_s) + ' (' + 
              order_detail.packaging_name + ') ' + number_with_precision(order_detail.quantity, precision: 2, delimiter: ',') + 
              order_detail.unit
  end
end
