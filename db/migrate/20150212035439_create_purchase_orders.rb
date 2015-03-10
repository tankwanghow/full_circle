class CreatePurchaseOrders < ActiveRecord::Migration
  def change
    create_table :purchase_orders do |t|
      t.date       :doc_date,     null: false
      t.date       :available_at, null: false
      t.belongs_to :supplier,     null: false
      t.text       :note
      t.integer    :lock_version, default: 0
      t.timestamps
    end

    create_table :purchase_order_details do |t|
      t.belongs_to :purchase_order,    null: false
      t.belongs_to :product,           null: false
      t.decimal    :quantity,          precision: 12, scale: 4, default: 0
      t.decimal    :unit_price,        precision: 12, scale: 4, default: 0
      t.belongs_to :product_packaging, null: false
      t.boolean    :fulfilled,         default: false
      t.boolean    :active,            default: false
      t.text       :note
    end
  end
end
