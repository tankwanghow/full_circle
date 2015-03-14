window.sales_order = {
  init: ->
    app.typeahead_init '#sales_order_customer_name1', '/account/typeahead_name1'
    detail.init()
}

