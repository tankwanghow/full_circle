class CreateSalesOrders < ActiveRecord::Migration
  def change
    create_table :sales_orders do |t|
      t.date       :doc_date,     null: false
      t.date       :deliver_at,   null: false
      t.belongs_to :customer,     null: false
      t.text       :note
      t.integer    :lock_version, default: 0
      t.timestamps
    end

    create_table :sales_order_details do |t|
      t.belongs_to :sales_order,       null: false
      t.belongs_to :product,           null: false
      t.belongs_to :deliver_to,        null: false
      t.belongs_to :product_packaging, null: false
      t.decimal    :package_qty,       precision: 12, scale: 4, default: 0
      t.decimal    :quantity,          precision: 12, scale: 4, default: 0
      t.decimal    :unit_price,        precision: 12, scale: 4, default: 0
      t.boolean    :status
      t.string     :note
    end
  end
end