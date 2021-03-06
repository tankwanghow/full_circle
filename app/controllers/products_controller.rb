class ProductsController < ApplicationController
  def edit
    @product = Product.find(params[:id])
  end

  def update
    @product = Product.find(params[:id])
    if @product.update_attributes(params[:product])
      flash[:success] = "Product '#{@product.name1}' updated successfully."
      redirect_to edit_product_path(@product)
    else
      flash.now[:error] = "Failed to updated Product."
      render :edit
    end
  end

  def new
    @product = Product.new(sale_account_name1: 'General Sales', purchase_account_name1: 'General Purchases')
  end

  def create
    @product = Product.new(params[:product])
    if @product.save
      flash[:success] = "Product '#{@product.name1}' created successfully."
      redirect_to edit_product_path(@product)
    else
      flash.now[:error] = "Failed to create Product."
      render :new
    end
  end

  def destroy
    @product = Product.find(params[:id])
    @product.destroy
    flash[:success] = "Successfully deleted '#{@product.name1}'."
    redirect_to product_new_or_edit_path
  end

  def new_or_edit
    if Product.first
      redirect_to edit_product_path(Product.last)
    else
      redirect_to new_product_path
    end
  end

  def typeahead_name1
    render json: typeahead_result(params[:term], "name1", Product)
  end

  def json
    p = Product.find_by_name1(params[:name1])
    if p
      if GstStarted
        tax_code = params[:gst_type] == 'supply' ? p.supply_tax_code_code : p.purchase_tax_code_code
      end
      render json: p.attributes.merge!(first_packaging_name: p.product_packagings.try(:first).try(:pack_qty_name), tax_code: tax_code)
    else
      render json: p
    end
  end

end
