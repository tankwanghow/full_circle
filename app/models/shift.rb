class Shift < ActiveRecord::Base
  validates_presence_of :name
  validates_presence_of :shift_late_in   
  validates_presence_of :shift_start_start  
  validates_presence_of :shift_start_actual
  validates_presence_of :shift_start_end
  validates_presence_of :shift_end_start    
  validates_presence_of :shift_end_actual
  validates_presence_of :shift_end_end     
  validates_presence_of :shift_early_out
  validates_presence_of :meal_early_out
  validates_presence_of :meal_start
  validates_presence_of :meal_end        
  validates_presence_of :meal_late_in 
end
