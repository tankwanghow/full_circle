window.purchase_order = {
  init: ->
    app.typeahead_init '#purchase_order_supplier_name1', '/account/typeahead_name1'
    app.typeahead_init '#purchase_order_product_name1', '/product/typeahead_name1'
    app.typeahead_init '#purchase_order_packaging_name', '/packaging/typeahead_product_package_name', (elm) ->
      product_json = elm.parents('form').find('#purchase_order_product_name1').data('product-json')
      { product_id: product_json.id } if product_json
    ($ 'form').on 'change', '#purchase_order_product_name1', ->
      elm = ($ this)
      $.get '/product/json', { name1: elm.val() }, (data) ->
        if data
          elm.parents('form').find('[name="unit"]').val(data.unit)
          elm.parents('form').find('#purchase_order_packaging_name').val(data.first_packaging_name)
          elm.data('product-json', data)
        else
          elm.parents('form').find('[name="unit"]').val('')
          elm.parents('form').find('#purchase_order_packaging_name').val('')
          elm.data('product-json', null)
}

