class ArrangementsController < ApplicationController
  def new
    sales_order_ids = params[:arrangement] ? params[:arrangement][:sales_orders] : []
    if sales_order_ids.count <= 0
      flash[:error] = "Please Select One or More Sales Orders."
      redirect_to new_sales_order_path
    else
      @arrangements = Arrangement.create_with_sales_orders!(sales_order_ids)
      render 'index'
    end
  end
end
