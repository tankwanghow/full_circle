class AddNicknameToAddress < ActiveRecord::Migration
  def change
    add_column :addresses, :nickname, :string
  end
end
