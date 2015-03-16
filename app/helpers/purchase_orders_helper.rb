module PurchaseOrdersHelper
  def render_purchase_order_details_fields builder, xies_name
    render 'share/nested_fields', f: builder, xies_name: xies_name, field: 'purchase_order_detail',
            headers: [['Product', 'span10'], ['Package', 'span6'], ['Pack', 'span4'], ['Note', 'span10'], 
                      ['Quantity', 'span6'], ['Unit', 'span3'], ['Price', 'span4'], ['A', 'span1'], ['F', 'span1']],
            text: 'Add Detail'
  end
end
