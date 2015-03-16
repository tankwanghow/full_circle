window.purchase_order = {
  init: ->
    app.typeahead_init '#purchase_order_supplier_name1', '/account/typeahead_name1'
    detail.init()
}

