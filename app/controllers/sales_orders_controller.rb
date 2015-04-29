class SalesOrdersController < ApplicationController
  def index
    store_param :sales_orders_find
    @sales_orders = SalesOrderDetail.query(session[:sales_orders_find][:term], session[:sales_orders_find][:date], session[:sales_orders_find][:fulfilled])
  end

  def edit
    @sales_order = SalesOrder.find(params[:id])
  end

  def new
    @sales_order = SalesOrder.new(doc_date: Date.today, deliver_at: Date.today + 1)
    @sales_order.details.build
  end

  def create
    @sales_order = SalesOrder.new(params[:sales_order])
    if @sales_order.save
      flash[:success] = "SalesOrder '##{@sales_order.id}' created successfully."
      redirect_to edit_sales_order_path(@sales_order)
    else
      flash.now[:error] = "Failed to create SalesOrder."
      render :new
    end
  end

  def update
    @sales_order = SalesOrder.find(params[:id])
    if @sales_order.update_attributes(params[:sales_order])
      flash[:success] = "SalesOrder '##{@sales_order.id}' updated successfully."
      redirect_to edit_sales_order_path(@sales_order)
    else
      flash.now[:error] = "Failed to update SalesOrder."
      render :edit
    end
  end

private

end
