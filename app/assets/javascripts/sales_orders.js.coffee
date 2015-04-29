window.sales_order = {
  init: ->
    app.typeahead_init '#sales_order_customer_name1', '/account/typeahead_name1'

    
    ($ 'input.sales_order_detail_index_row').on 'click', ->
      if this.checked
        ($ this).parents('tr').addClass('active')
      else
        ($ this).parents('tr').removeClass('active')

    detail.init()
}

