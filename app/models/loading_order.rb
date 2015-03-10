class LoadingOrder < ActiveRecord::Base
  attr_accessible :doc_date, :lorry_no, :purchase_order_id, :sales_order_id, :transporter_id
end
