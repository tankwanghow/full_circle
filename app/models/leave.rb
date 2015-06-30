class Leave < ActiveRecord::Base
  attr_accessible :annual_leave_days, :hospitalize_leave_days, :name, :serviced_years, :sick_leave_days, :special_leave_days
end
