class AddShiftToEmployee < ActiveRecord::Migration
  def change
    add_column :employees, :shift_id, :integer
  end
end
