class CreateLoadingOrders < ActiveRecord::Migration
  def change
    create_table :loading_orders do |t|
      t.date       :doc_date,        null: false      
      t.belongs_to :transporter
      t.string     :lorry_no
      t.text       :note
      t.integer    :lock_version, default: 0
      t.timestamps
    end
  end
end
