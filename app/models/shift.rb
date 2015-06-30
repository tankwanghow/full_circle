class Shift < ActiveRecord::Base
  validates_presence_of :name
  validates_presence_of :shift_days
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
  has_many :employees
  
  include Searchable
  searchable content: [:name, :shift_start_actual, :shift_end_actual, :overnight]

  simple_audit username_method: :username do |r|
    {
      name: r.name,
      shift_days: r.shift_days,
      overnight: r.overnight,
      shift_late_in: r.shift_late_in,
      shift_start_start: r.shift_start_start,
      shift_start_actual: r.shift_start_actual,
      shift_start_end: r.shift_start_end,
      shift_end_start: r.shift_end_start,
      shift_end_actual: r.shift_end_actual,
      shift_end_end: r.shift_end_end,
      shift_early_out: r.shift_early_out,
      meal_early_out: r.meal_early_out,
      meal_start: r.meal_start,
      meal_end: r.meal_end,
      meal_late_in: r.meal_late_in
    }
  end
end
