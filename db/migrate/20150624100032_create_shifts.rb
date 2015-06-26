class CreateShifts < ActiveRecord::Migration
  def change
    create_table :shifts do |t|
      t.string  :name,            null: false
      t.time    :start_s,         null: false
      t.time    :start_e,         null: false
      t.integer :start_allowance, null: false, default: 0
      t.time    :break_s,         null: false
      t.time    :break_e,         null: false
      t.integer :break_allowance, null: false, default: 0
      t.time    :end_s,           null: false
      t.time    :end_e,           null: false
      t.integer :end_allowance,   null: false, default: 0
      t.time    :ot_s,            null: false
      t.time    :ot_e,            null: false
      t.integer :ot_allowance,    null: false, default: 0
      t.integer :lock_version,    default: 0
      t.timestamps
    end
  end
end
