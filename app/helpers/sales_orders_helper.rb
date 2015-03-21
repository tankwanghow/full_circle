module SalesOrdersHelper
  def render_sales_order_details_fields builder, xies_name
    render 'share/nested_fields', f: builder, xies_name: xies_name, field: 'sales_order_detail',
            headers: [['Product', 'span10'], ['Package', 'span5'], ['Pack', 'span3'], ['Note', 'span10'], 
                      ['Quantity', 'span5'], ['Balance', 'span5'], ['Unit', 'span3'], ['Price', 'span4'], ['F', 'span1']],
            text: 'Add Detail'
  end
end
