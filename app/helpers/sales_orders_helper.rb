module SalesOrdersHelper
  def render_sales_order_details_fields builder, xies_name
    render 'share/nested_fields', f: builder, xies_name: xies_name, field: 'sales_order_detail',
            headers: [['Product', 'span10'], ['Package', 'span5'], ['Pack', 'span3'], ['Note', 'span10'],
                      ['Quantity', 'span5'], ['Balance', 'span5'], ['Unit', 'span3'], ['Price', 'span4'], ['F', 'span1']],
            text: 'Add Detail'
  end

  def arrangements_info order_detail
    arranged_info(order_detail) +
    loaded_info(order_detail) +
    delivered_info(order_detail)
  end

  def arranged_info order_detail
    label_tag dom_id(order_detail), "Arranged #{order_detail.arranged.count}", class: 'label label-success'
  end

  def loaded_info order_detail
    label_tag dom_id(order_detail), "Loaded #{order_detail.loaded.count} (#{order_detail.loaded.sum(&:load_quantity)}#{order_detail['unit']})", class: 'label label-warning'
  end

  def delivered_info order_detail
    label_tag dom_id(order_detail), "Delivered #{order_detail.delivered.sum(&:deliver_quantity)}#{order_detail['unit']})", class: 'label label-info'
  end

  def sales_order_product_info order_detail
    label_tag dom_id(order_detail), order_detail["product_name"] + ' ' +
              (order_detail["package_qty"].to_i == 0 ? '' : order_detail["package_qty"].to_i.to_s) + ' (' +
              order_detail["packaging_name"] + ') ' + 
              number_with_precision(order_detail["quantity"], precision: 2, delimiter: ',') +
              order_detail["unit"] + ' ' + order_detail["detail_note"]
  end
end
