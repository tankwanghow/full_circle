class LoadingOrdersController < ApplicationController

  def edit
    @loading_order = LoadingOrder.find(params[:id])
  end

  def new
    @loading_order = LoadingOrder.new(doc_date: Date.today)
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

end
