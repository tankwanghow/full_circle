class PurchaseOrdersController < ApplicationController

  def index
    redirect_to new_purchase_order_path
  end

  def edit
    @purchase_order = PurchaseOrder.find(params[:id])
  end

  def new
    @purchase_order = PurchaseOrder.new(doc_date: Date.today, available_at: Date.today + 1)
    @purchase_order.details.build
  end

  def create
    @purchase_order = PurchaseOrder.new(params[:purchase_order])
    if @purchase_order.save
      flash[:success] = "PurchaseOrder '##{@purchase_order.id}' created successfully."
      redirect_to edit_purchase_order_path(@purchase_order)
    else
      flash.now[:error] = "Failed to create PurchaseOrder."
      render :new
    end
  end

  def update
    @purchase_order = PurchaseOrder.find(params[:id])
    if @purchase_order.update_attributes(params[:purchase_order])
      flash[:success] = "PurchaseOrder '##{@purchase_order.id}' updated successfully."
      redirect_to edit_purchase_order_path(@purchase_order)
    else
      flash.now[:error] = "Failed to update PurchaseOrder."
      render :edit
    end
  end

end
