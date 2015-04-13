window.loading_order = {
  init: ->
    app.typeahead_init '#loading_order_transporter_name1', '/account/typeahead_name1'
    app.typeahead_init '#loading_order_lorry_no', '/loading_order/typeahead_lorry_no'
}