class CreateArrangements < ActiveRecord::Migration
  def change
    create_table :arrangements do |t|
      t.belongs_to :sales_order_detail
      t.belongs_to :purchase_order_detail
      t.belongs_to :loading_order
      t.string     :note
      t.decimal    :order_quantity, precision: 12, scale: 4, default: 0
      t.date       :loaded_date
      t.decimal    :load_quantity, precision: 12, scale: 4, default: 0
      t.date       :deliver_date
      t.decimal    :deliver_quantity, precision: 12, scale: 4, default: 0
      t.boolean    :canceled, default: false
      t.belongs_to :invoice_detail
      t.belongs_to :pur_invoice_detail
      t.integer    :lock_version, default: 0
      t.timestamps
    end
  end
end
