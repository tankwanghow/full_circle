window.sales_order = {
  init: ->
    app.typeahead_init '#sales_order_customer_name1', '/account/typeahead_name1'
    ($ 'input.sales_order_detail_index_row').on 'click', ->
      if this.checked
        ($ this).parents('tr').addClass('active')
      else
        ($ this).parents('tr').removeClass('active')
      sales_order.query_arrangements()
    detail.init()

  query_arrangements: ->
    a = []
    $('#sales_orders tbody tr.active td input[type=checkbox]').each (index, elm) ->
      a.push elm.name.match(/\d+/)[0]
    $.get '/arrangements', 
      sales_order_detail_ids: a.join(',')
      , (data) -> 
        ($ '#loading_orders').html(data)
        
}

