class LoadingOrdersController < ApplicationController

  def edit
    @loading_order = LoadingOrder.find(params[:id])
  end

  def new
    @sales_order_detail_ids = params[:sales_order_detail_ids].select{ |k, v| v == "1" }.map{|k,v| k }
    @loading_order = LoadingOrder.new(doc_date: Date.today)
    @sales_order_detail_ids.each do |id|
      @loading_order.arrangements.build(sales_order_detail_id: id, load_date: Date.today + 1)
    end
  end

  def create
    @loading_order = LoadingOrder.new(params[:loading_order])
    if @loading_order.save
      flash[:success] = "LoadingOrder '##{@loading_order.id}' created successfully."
      redirect_to edit_loading_order_path(@loading_order)
    else
      flash.now[:error] = "Failed to create LoadingOrder."
      render :new
    end
  end

  def update
    @loading_order = LoadingOrder.find(params[:id])
    if @loading_order.update_attributes(params[:loading_order])
      flash[:success] = "LoadingOrder '##{@loading_order.id}' updated successfully."
      redirect_to edit_loading_order_path(@loading_order)
    else
      flash.now[:error] = "Failed to update LoadingOrder."
      render :edit
    end
  end

  def typeahead_lorry_no
    render json: typeahead_result(params[:term], "lorry_no", LoadingOrder)
  end
end
