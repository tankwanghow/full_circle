class ArrangementsController < ApplicationController
  def index
    ids = params[:sales_order_detail_ids].split(',').map { |t| t.to_i }
    if ids.count > 0
      @arrangements = Arrangement.where(sales_order_detail_id: ids) 
      render :index, layout: false
    else
      render text: "", layout: false
    end 
  end
end
