class SalesOrder < ActiveRecord::Base
  belongs_to :customer, class_name: "Account"
  has_many :details, :class_name => "SalesOrderDetail"

  include ValidateBelongsTo
  validate_belongs_to :customer, :name1

  accepts_nested_attributes_for :details, allow_destroy: true

  include Searchable
  searchable doc_date: :doc_date,
             content: [:id, :customer_name1, :details_audit_string, :deliver_at, :note]

  include AuditString
  audit_string :details

  simple_audit username_method: :username do |r|
     {
      doc_date: r.doc_date.to_s,
      deliver_at: r.deliver_at.to_s,
      customer: r.customer_name1,
      details: r.details_audit_string,
      note: r.note
     }
  end
end
