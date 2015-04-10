class ArrangementsController < ApplicationController
  def create
    @arrangement = Arrangement.new(params[:arrangement])
    @arrangement.save
    redirect_to sales_orders_path
  end

  def index
    @arrangements = Arrangement.where(sales_order_detail_id: params[])
  end
end
