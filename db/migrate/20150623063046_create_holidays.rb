class CreateHolidays < ActiveRecord::Migration
  def change
    create_table :holidays do |t|
      t.string     :name,          null: false
      t.date       :holidate,      null: false
      t.float      :pay_multiplier, default: 1, null: false
      t.timestamps
    end
  end
end
