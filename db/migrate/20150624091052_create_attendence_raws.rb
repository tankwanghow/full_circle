class CreateAttendenceRaws < ActiveRecord::Migration
  def change
    create_table :attendence_raws do |t|
      t.belongs_to :employee, null: false
      t.datetime   :timed_at, null: false
      t.string     :flag,     null: false
    end
    add_index :attendence_raws, [:employee_id, :timed_at], name: 'attendence_raws_index', unique: true
  end
end
