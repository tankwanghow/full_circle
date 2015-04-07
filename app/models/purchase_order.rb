class PurchaseOrder < ActiveRecord::Base
  belongs_to :supplier, class_name: "Account"
  has_many :details, :class_name => "PurchaseOrderDetail"

  include ValidateBelongsTo
  validate_belongs_to :supplier, :name1

  accepts_nested_attributes_for :details, allow_destroy: true
  
  include Searchable
  searchable doc_date: :doc_date, 
             content: [:id, :supplier_name1, :details_audit_string, :available_at, :note]

  include AuditString
  audit_string :details
end