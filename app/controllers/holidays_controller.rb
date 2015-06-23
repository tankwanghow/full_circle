class HolidaysController < ApplicationController
  def edit
    @holiday = Holiday.find(params[:id])
  end

  def new
    @holiday = Holiday.new
  end

  def create
    @holiday = Holiday.new(params[:holiday])
    if @holiday.save
      flash[:success] = "Holiday '##{@holiday.name}' created successfully."
      redirect_to edit_holiday_path(@holiday)
    else  
      flash.now[:error] = "Failed to create Holiday."
      render :new
    end
  end

  def update
    @holiday = Holiday.find(params[:id])
    if @holiday.update_attributes(params[:holiday])
      flash[:success] = "Holiday '##{@holiday.name}' updated successfully."
      redirect_to @holiday
    else
      flash.now[:error] = "Failed to update Holiday."
      render :edit
    end
  end

  def new_or_edit
    if Holiday.first
      redirect_to Holiday.last
    else
      redirect_to new_holiday_path
    end
  end 
end
