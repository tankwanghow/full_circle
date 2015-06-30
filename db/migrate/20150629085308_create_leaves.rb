class CreateLeaves < ActiveRecord::Migration
  def change
    create_table :leaves do |t|
      t.string :name
      t.integer :serviced_years
      t.integer :sick_leave_days
      t.integer :annual_leave_days
      t.integer :hospitalize_leave_days
      t.integer :special_leave_days
      t.integer :lock_version, default: 0
      t.timestamps
    end
  end
end
