class LoadingOrder < ActiveRecord::Base
  belongs_to :transporter, class_name: "Account"
  has_many :arrangements

  accepts_nested_attributes_for :arrangements, allow_destroy: true
end
