class CreateShifts < ActiveRecord::Migration
  def change
    create_table :shifts do |t|
      t.string  :name,               null: false
      t.integer :shift_late_in,      null: false, default: 0
      t.time    :shift_start_start,  null: false
      t.time    :shift_start_actual, null: false
      t.time    :shift_start_end,    null: false
      t.time    :shift_end_start,    null: false
      t.time    :shift_end_actual,   null: false
      t.time    :shift_end_end,      null: false
      t.integer :shift_early_out,    null: false, default: 0
      t.boolean :overnight,          null: false, default: false
      t.integer :meal_early_out,     null: false, default: 0
      t.time    :meal_start,         null: false
      t.time    :meal_end,           null: false
      t.integer :meal_late_in,       null: false, default: 0
      t.integer :shift_days,         null: false, default: 6
      t.integer :lock_version,       default: 0
      t.timestamps
    end
  end
end
