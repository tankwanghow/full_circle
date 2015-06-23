class Address < ActiveRecord::Base
  validates_presence_of :addressable_type, :addressable_id, :address_type
  belongs_to :addressable, polymorphic: true
  validates :address_type, one_mailing_address: true
  validates_uniqueness_of :nickname, on: :create, message: "must be unique", if: proc { |obj| !obj.nickname.blank? }

  simple_audit username_method: :username do |r|
    {
      addressable_type: r.addressable_type,
      addressable_id: r.addressable_id,
      address: [r.address1, r.address2, r.address3, r.zipcode,
                r.city, r.state, r.country].compact.join(", "),
      tel_no: r.tel_no,
      fax_no: r.fax_no,
      email: r.email,
      reg_no: r.reg_no,
      gst_no: r.gst_no,
      nickname: r.nickname,
      note: r.note
    }
  end

  def self.address_types
    ["Shipping", "Mailing", "Both"]
  end

end
