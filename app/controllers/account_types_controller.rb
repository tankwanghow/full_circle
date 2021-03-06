class AccountTypesController < ApplicationController

  def edit
    @account_type = AccountType.find(params[:id])
  end

  def update
    @account_type = AccountType.find(params[:id])
    admin_lock_check @account_type
    if @account_type.update_attributes(params[:account_type])
      flash[:success] = "Account Type '#{@account_type.name}' updated successfully."
      redirect_to edit_account_type_path(@account_type)
    else
      flash.now[:error] = "Failed to updated Account Type."
      render :edit
    end
  end

  def new
    @account_type = AccountType.new(parent_id: params[:parent_id])
  end

  def create
    @account_type = AccountType.new(params[:account_type])
    if @account_type.save
      flash[:success] = "Account Type '#{@account_type.name}' created successfully."
      redirect_to edit_account_type_path(@account_type)
    else
      flash.now[:error] = "Failed to create Account Type."
      render :new
    end
  end

  def destroy
    @account_type = AccountType.find(params[:id])
    admin_lock_check @account_type
    @account_type.destroy
    flash[:success] = "Successfully deleted '#{@account_type.name}'."
    if @account_type.parent
      redirect_to edit_account_type_path(@account_type.parent)
    else
      redirect_to edit_account_type_path(AccountType.first)
    end
  end

  def typeahead_name
    render json: typeahead_result(params[:term], "name", AccountType)
  end

  def typeahead_name_combine_account
    data =  typeahead_result(params[:term], "name", AccountType)
    data << typeahead_result(params[:term], "name1", Account)
    render json: data.flatten
  end  

end
