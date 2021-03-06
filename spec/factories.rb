require 'ffaker'

FactoryGirl.define do
  factory :user do
    username { Faker::Internet.user_name }
    name { Faker::Name.name }
    password "secret"
    password_confirmation "secret"

    factory :invalid_user do
      password_confirmation { 'mama' }
      password { 'papa' }
    end

    factory :active_user do
      status { :active }
    end

  end

  factory :account do
    account_type { [create(:account_type), AccountType.first(order: 'random()')].fetch rand(2) }
    name1 { Faker::Name.name }
    name2 { Faker::Name.name }
    description { Faker::Lorem.sentence }
    status { ['Active', 'Dormant'].fetch rand(2) }

    factory :active_account do
      status 'Active'
    end

    factory :dormant_account do
      status 'Dormant'
    end
  end

  factory :account_type do
    parent { [nil, AccountType.first(order: 'random()')].fetch rand(2) }
    name { Faker::Name.name }
    normal_balance { ['debit', 'credit'].fetch rand(2) }
    bf_balance { [true, false].fetch(rand(2)) }
    description { Faker::Lorem.sentence }
  end

  factory :particular_type do
    party_type { [nil, 'Incomes', 'Expenses'].fetch rand(3) }
    name { Faker::Name.name }
    account

    factory :nil_particular_type do
      party_type nil
      account nil
    end

    factory :incomes_particular_type do
      party_type 'Incomes'
    end

    factory :expenses_particular_type do
      party_type 'Expenses'
    end
  end

  factory :product do
    name1 { Faker::Name.name }
    name2 { Faker::Name.name }
    description { Faker::Lorem.sentence }
    unit { Faker::Internet.user_name.slice 3..5 } 
    sale_account { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }
    purchase_account { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }
  end

  factory :particular do
    particular_type do 
      [ create(:incomes_particular_type), 
        create(:expenses_particular_type), 
        create(:nil_particular_type), 
        ParticularType.first(order: 'random()')].fetch rand(4) 
    end
    note { Faker::Lorem.sentence }
    quantity { rand(10) * rand(10) }
    unit { Faker::Internet.user_name.slice 3..5 }
    unit_price { rand(10) * rand(10) }
  end

  factory :payment_particular do
    flag { ['pay_to', 'pay_from'].fetch rand(2) }
    particular_type do 
      [ create(:incomes_particular_type), 
        create(:expenses_particular_type), 
        create(:nil_particular_type), 
        ParticularType.first(order: 'random()')].fetch rand(4) 
    end
    note { Faker::Lorem.sentence }
    quantity { rand(10) * rand(10) }
    unit { Faker::Internet.user_name.slice 3..5 }
    unit_price { rand(10) * rand(10) }

    factory :payment_pay_from_particular do
      flag 'pay_form'
    end

    factory :payment_pay_to_particular do
      flag 'pay_to'
    end
  end

  factory :payment do
    pay_to { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }
    pay_from { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }
    doc_date { Date.current - rand(10) }
    collector { Faker::Name.name }
    actual_credit_amount 1
    actual_debit_amount 1
  end

  factory :employee do
    name { Faker::Name.name }
    id_no { Faker::PhoneNumber.phone_number }
    birth_date { Date.today - (rand(18..55) * 365) }
    epf_no { Faker::PhoneNumber.phone_number }
    socso_no { Faker::PhoneNumber.phone_number }
    tax_no { Faker::PhoneNumber.phone_number }
    nationality { ['Malaysian', 'Indonesian', 'Nepalest', 'Burmist'].fetch rand(3) }
    marital_status { ['Single', 'Married'].fetch rand(2) }
    partner_working { [true, false].fetch rand(2) }
    service_since { Date.today - (rand(0..17) * 365) }
    children { rand(8) }
  end

  factory :salary_type do
    name { Faker::Name.name }
    classifiaction { ['Addition', 'Deduction'].fetch rand(2) }
    db_account { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }
    cr_account { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }
  end

  factory :employee_salary_type do
    employee { [create(:employee), Employee.first(order: 'random()')].fetch rand(2) }
    salary_type { [create(:salary_type), SalaryType.first(order: 'random()')].fetch rand(2) }
    amount { rand(10000) }
  end

  factory :advance do
    doc_date { Date.current - rand(30) }
    employee { [create(:employee), Employee.first(order: 'random()')].fetch rand(2) }
    pay_from { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }    
    chq_no { Faker::PhoneNumber.phone_number }
    amount { rand * rand(1000..5000) }
  end

  factory :salary_note do
    doc_date { Date.current - rand(30) }
    employee { [create(:employee), Employee.first(order: 'random()')].fetch rand(2) }
    salary_type { [create(:salary_type), SalaryType.first(order: 'random()')].fetch rand(2) }
    note { Faker::Lorem.sentence }
    quantity { rand(30) }
    unit { '-' }
    unit_price { rand(21..100) }
  end

  factory :recurring_note do
    doc_date { Date.current - rand(30) }
    employee { [create(:employee), Employee.first(order: 'random()')].fetch rand(2) }
    salary_type { [create(:salary_type), SalaryType.first(order: 'random()')].fetch rand(2) }
    note { Faker::Lorem.sentence }
    amount { rand(100..500) }
    target_amount { rand(500..1000) }
    start_date { Date.current - rand(30) }
    end_date { Date.current - rand(300) }
  end

  factory :pay_slip do
    doc_date { Date.current - rand(30) }
    employee { [create(:employee), Employee.first(order: 'random()')].fetch rand(2) }
    pay_from { [create(:active_account), Account.first(order: 'random()')].fetch rand(2) }    
    pay_date { Date.current - rand(30) }
    chq_no { Faker::PhoneNumber.phone_number }
  end

end