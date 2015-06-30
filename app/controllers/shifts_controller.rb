class ShiftsController < ApplicationController

  def edit
    @shift = Shift.find(params[:id])
  end

  def new
    @shift = Shift.new
  end

  def create
    @shift = Shift.new(params[:shift])
    if @shift.save
      flash[:success] = "Shift '##{@shift.id}' created successfully."
      redirect_to edit_shift_path(@shift)
    else
      flash.now[:error] = "Failed to create Shift."
      render :new 
    end
  end

  def update
    @shift = Shift.find(params[:id])
    if @shift.update_attributes(params[:shift])
      flash[:success] = "Shift '##{@shift.id}' updated successfully."
      redirect_to edit_shift_path(@shift)
    else
      flash.now[:error] = "Failed to update Shift."
      render :edit
    end
  end

  def new_or_edit
    if Shift.first
      redirect_to edit_shift_path(Shift.last)
    else
      redirect_to new_shift_path
    end
  end

  def typeahead_name
    render json: typeahead_result(params[:term], "name", Shift)
  end

end

