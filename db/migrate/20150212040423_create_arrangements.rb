class CreateArrangements < ActiveRecord::Migration
  def change
    create_table :arrangements do |t|
      t.belongs_to :order_detail
      t.belongs_to :purchase_order_detail
      t.belongs_to :loading_order_detail
      t.belongs_to :invoice_detail
      t.belongs_to :pur_invoice_detail
      t.integer :lock_version, default: 0
      t.timestamps
    end
  end
end
