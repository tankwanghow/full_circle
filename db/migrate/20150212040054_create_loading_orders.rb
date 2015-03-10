class CreateLoadingOrders < ActiveRecord::Migration
  def change
    create_table :loading_orders do |t|
      t.date       :doc_date, null: false      
      t.belongs_to :transporter
      t.string     :lorry_no
      t.text       :note
      t.integer    :lock_version, default: 0
      t.timestamps
    end

    create_table :loading_order_detail do |t|
      t.belongs_to :order_detail
      t.belongs_to :purchase_order_detail
      t.date       :loaded_at
      t.decimal    :load_quantity, precision: 12, scale: 4, default: 0
      t.date       :deliver_at
      t.decimal    :deliver_quantity, precision: 12, scale: 4, default: 0
      t.text       :note
    end
  end
end
