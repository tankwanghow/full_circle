FullCircle::Application.routes.draw do

  match 'login' => 'sessions#new', as: :login
  match 'logout' => 'sessions#destroy', as: :logout
  match 'signup' => 'users#new', as: :signup
  match 'search' => 'main#index', as: :search
  match 'transactions' => 'transactions#index', as: :transactions
  match 'matchers' => 'matchers#index'
  match 'depositable_cheques' => 'cheques#depositable'
  match 'get_return_cheque' => 'cheques#return_cheque'
  match 'batch_print_docs' => 'batch_print_docs#index'
  match 'print_batch_print_docs' => 'batch_print_docs#print'

  resources :statements, only: [:new, :create]
  resources :feed_usages
  resources :feed_productions

  root to: 'main#index'
  resources :audit_logs, only: :index

  resources :printing_in_batches, only: [:new, :create]

  resources :holidays, only: [:new, :edit, :update, :create, :destroy]

  resources :tax_codes, only: [:new, :edit, :update, :create, :destroy]
  get 'tax_code/new_or_edit' => 'tax_codes#new_or_edit'
  get 'tax_code/typeahead_code' => 'tax_codes#typeahead_code'
  get 'tax_code/typeahead_tax_type' => 'tax_codes#typeahead_tax_type'
  get 'tax_code/json' => 'tax_codes#json'

  resources :particular_types, only: [:new, :edit, :update, :create, :destroy]
  get 'particular_type/json' => 'particular_types#json'
  get 'particular_type/new_or_edit' => 'particular_types#new_or_edit'
  get 'particular_type/typeahead_name' => 'particular_types#typeahead_name'

  resources :products, only: [:new, :edit, :update, :create, :destroy]
  get 'product/json' => 'products#json'
  get 'product/new_or_edit' => 'products#new_or_edit'
  get 'product/typeahead_name1' => 'products#typeahead_name1'

  resources :users, only: [:new, :edit, :update, :create, :destroy]
  resources :accounts, only: [:new, :edit, :update, :create, :destroy]
  get 'account/typeahead_name1' => 'accounts#typeahead_name1'

  resources :posts, only: [:new, :edit, :update, :create, :destroy, :show]
  get 'post/new_or_edit' => 'posts#new_or_edit'

  resources :account_types, only: [:new, :edit, :update, :create, :destroy]
  get 'account_type/typeahead_name' => 'account_types#typeahead_name'
  get 'account_type/typeahead_name_combine_account' => 'account_types#typeahead_name_combine_account'

  resource :sessions, only: [:new, :create, :destroy]
  resources :addresses, only: [:new, :edit, :update, :create, :destroy]
  resources :fixed_assets, only: [:new, :edit, :update, :create, :destroy]
  resources :asset_additions, only: [:edit, :update]
  
  resources :salary_types, only: [:new, :edit, :update, :create, :destroy]
  get 'salary_type/new_or_edit' => 'salary_types#new_or_edit'
  get 'salary_type/json' => 'salary_types#json'
  get 'salary_type/typeahead_name' => 'salary_types#typeahead_name'

  resources :employees, only: [:new, :edit, :update, :create, :destroy]
  get 'employee/typeahead_name' => 'employees#typeahead_name'    
  get 'employee/new_or_edit' => 'employees#new_or_edit'
  get 'employees/new_with_template' => 'employees#new_with_template'

  resources :payments, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'payment/new_or_edit' => 'payments#new_or_edit'
  get 'payment/typeahead_collector' => 'payments#typeahead_collector'

  resources :matching_payments, only: [:new, :edit, :show]
  get 'matching_payment/new_or_edit' => 'matching_payments#new_or_edit'
  
  resources :invoices, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'invoice/new_or_edit' => 'invoices#new_or_edit'

  resources :pay_slips, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'pay_slip/new_or_edit' => 'pay_slips#new_or_edit'

  resources :pay_slip_generations, only: [:new, :create, :index]

  get 'cash_sales/new_with_template' => 'cash_sales#new_with_template'
  resources :cash_sales, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'cash_sale/new_or_edit' => 'cash_sales#new_or_edit'

  resources :receipts, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'receipt/new_or_edit' => 'receipts#new_or_edit'

  resources :advances, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'advance/new_or_edit' => 'advances#new_or_edit'

  resources :salary_notes, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'salary_note/new_or_edit' => 'salary_notes#new_or_edit'

  resources :recurring_notes, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'recurring_note/new_or_edit' => 'recurring_notes#new_or_edit'

  resources :deposits, only: [:new, :edit, :update, :create] do
    resources :journal_entries, only: [:index]
  end
  get 'deposit/new_or_edit' => 'deposits#new_or_edit'

  resources :return_cheques, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'return_cheque/new_or_edit' => 'return_cheques#new_or_edit'
  get 'return_cheque/typeahead_reason' => 'return_cheques#typeahead_reason'

  resources :pur_invoices, only: [:new, :edit, :update, :create] do
    resources :journal_entries, only: [:index]
  end
  get 'pur_invoice/new_or_edit' => 'pur_invoices#new_or_edit'

  resources :credit_notes, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'credit_note/new_or_edit' => 'credit_notes#new_or_edit'

  resources :debit_notes, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'debit_note/new_or_edit' => 'debit_notes#new_or_edit'

  resources :packagings, only: [:new, :edit, :update, :create, :destroy]
  get 'packaging/new_or_edit' => 'packagings#new_or_edit'
  get 'packaging/typeahead_product_package_name' => 'packagings#typeahead_product_package_name'
  get 'packaging/typeahead_name' => 'packagings#typeahead_name'
  get 'packaging/json' => 'packagings#json'

  resources :journals, only: [:new, :edit, :update, :create, :show] do
    resources :journal_entries, only: [:index]
  end
  get 'journal/new_or_edit' => 'journals#new_or_edit' 

  resources :flocks, only: [:new, :edit, :update, :create]
  get 'flock/new_or_edit' => 'flocks#new_or_edit'
  get 'flock/typeahead_breed' => 'flocks#typeahead_breed'
  get 'flock/info' => 'flocks#info'

  resources :houses, only: [:new, :edit, :update, :create]
  get 'house/new_or_edit' => 'houses#new_or_edit'

  resources :harvesting_slips, only: [:new, :edit, :update, :create]
  get 'harvesting_slip/new_or_edit' => 'harvesting_slips#new_or_edit'

  resources :harvesting_reports, only: [:new, :create]
  resources :harvesting_wages_reports, only: [:new, :create]
  get 'driver_commissions' => 'driver_commissions#show'

  resources :fixed_asset_addition_confirmations, only: [:index, :create]
  post 'fixed_asset_addition_confirmations/confirm_all' => 'fixed_asset_addition_confirmations#confirm_all'

  resources :fixed_asset_depreciation_confirmations, only: [:index, :create]
  post 'fixed_asset_depreciation_confirmations/confirm_all' => 'fixed_asset_depreciation_confirmations#confirm_all'

  resources :print_harvesting_slips, only: [:create, :index]

  resources :gst_accounts, only: [:index, :create]

  resources :queries

  resources :sales_orders
  resources :purchase_orders
  resources :loading_orders
  resources :arrangements

end
