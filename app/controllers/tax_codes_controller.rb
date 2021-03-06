class TaxCodesController < ApplicationController
  def edit
    @tax_code = TaxCode.find(params[:id])
  end

  def update
    @tax_code = TaxCode.find(params[:id])
    if @tax_code.update_attributes(params[:tax_code])
      flash[:success] = "Tax Code '#{@tax_code.code}' updated successfully."
      redirect_to edit_tax_code_path(@tax_code)
    else
      flash.now[:error] = "Failed to updated Tax Code."
      render :edit
    end
  end

  def new
    @tax_code = TaxCode.new
  end

  def create
    @tax_code = TaxCode.new(params[:tax_code])
    if @tax_code.save
      flash[:success] = "Tax Code '#{@tax_code.code}' created successfully."
      redirect_to edit_tax_code_path(@tax_code)
    else
      flash.now[:error] = "Failed to create Tax Code."
      render :new
    end
  end

  def destroy
    @tax_code = TaxCode.find(params[:id])
    @tax_code.destroy
    flash[:success] = "Successfully deleted '#{@tax_code.code}'."
    redirect_to tax_code_new_or_edit_path
  end

  def new_or_edit
    if TaxCode.first
      redirect_to edit_tax_code_path(TaxCode.last)
    else
      redirect_to new_tax_code_path
    end
  end

  def typeahead_code
    term = "%#{params[:term].scan(/(\w)/).flatten.join('%')}%"
    render json: TaxCode.where('code ilike ?', term).limit(20).pluck(:code)
  end

  def typeahead_tax_type
    term = "%#{params[:term].scan(/(\w)/).flatten.join('%')}%"
    render json: TaxCode.uniq.where('tax_type ilike ?', term).limit(8).pluck(:tax_type)
  end

  def json
    p = TaxCode.find_by_code(params[:code])
    render json: p.try(:attributes)
  end
end
