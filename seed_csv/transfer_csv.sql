-- Accounts
-- Try to get all the General Ledger Account to the new system
SELECT at2.dotted_ids , at2."name" as account_type, a.name1 as name, a.description
  from accounts a inner join account_types at2 
    on a.account_type_id = at2.id
 where true
   and at2.dotted_ids not ilike '1.8%' 
   and at2.dotted_ids not ilike '1.2.6.7%'
   and at2.dotted_ids not ilike '1.2.6.26%'
   and at2.dotted_ids not ilike '9.10.11.23%'
   and at2.dotted_ids not ilike '9.10.11.12%'
   and at2.dotted_ids not ilike '9.10.11.14%'
   order by 1

-- employees
select name,id_no,birth_date as dob ,epf_no,socso_no,tax_no,nationality,marital_status,partner_working,service_since,children,status,sex as gender 
 from employees;

-- employee_salary_types
select e.name as employee_name,st.name as salary_type_name,amount
from employees e inner join employee_salary_types est  on e.id = est.employee_id 
inner join salary_types st on st.id = est.sal

 -- Contacts
 select act.name, ac.name1, ac.id, address1 || ' ' || address2 as address1, address3  || ' ' ||  area as address2,  city, state, zipcode, country, 
       'Tel. ' || tel_no || ' Fax. ' as contact_info, email, reg_no, 'GST No. ' || gst_no || ' ' || note as descriptions
  from accounts ac left outer join addresses ad 
    on ac.id = ad.addressable_id
   and addressable_type = 'Account' inner join account_types act
    on act.id = ac.account_type_id
   where act.name ilike '%creditor%'
      or act.name ilike '%debtor%'
      or act.name ilike '%agents%'
order by 1

 ----!!!!  MAKE SURE CONTACT AND ACCOUNT ARE UP-TO-DATE BEFORE SEEDING TRANSACTIONS !!!!!----

-- FixedAssets
-- Fixed Assets Account
-- Use Rails FullCircle Depreciation Worksheet Export to CSV.


-- Transactions
select t.transaction_date as doc_date, a.name1 as account_name, t.doc_id as doc_no, 
       t.doc_type as doc_type, t.note as particulars, t.amount as amount 
  from accounts a inner join transactions t 
    on t.account_id = a.id
 where t.transaction_date >= '2023-01-01'


-- TransactionMatchers
select a.name1 as account_name, tm.doc_date as m_doc_date, tm.doc_id as m_doc_id, tm.doc_type as m_doc_type, tm.amount as m_amount,
       t.transaction_date as n_doc_date, t.doc_id as n_doc_id, t.doc_type as n_doc_type, t.amount as n_amount
  from transaction_matchers tm inner join transactions t 
    on t.id = tm.transaction_id inner join accounts a
    on a.id = t.account_id
 where tm.doc_date >= '2023-01-01'
 order by 2, 4, 3

-- flocks
select replace(f.dob::varchar, '-',	'') || '-' || f.id::varchar as flock_no,
	     dob,	quantity,	breed,	note
  from flocks f

-- movements
select m.move_date, h.house_no,	replace(f.dob::varchar,	'-',	'') || '-' || f.id::varchar as flock_no,
	     m.quantity, m.note
from movements m inner join houses h 
  on h.id = m.house_id inner join flocks f 
  on f.id = m.flock_id

-- Harvest
select 'HS-old-' || hs.id::varchar as harvest_no, hs.harvest_date as har_date, coalesce(e.name, 'Tan Liew Cheun') as employee_name
  from harvesting_slips hs left outer join employees e 
    on e.id = hs.collector_id 
 where hs.harvest_date <= '2023-10-31'

 -- Harvest Details
 select 'HS-old-' || hs.id::varchar as harvest_no, h.house_no as house_no,
       replace(f.dob::varchar, '-', '') || '-' || f.id::varchar,
       hsd.harvest_1 as har_1, hsd.harvest_2 as har_2, 0 as har_3, hsd.death as dea_1, 0 as dea_2,
       hsd.note as note
  from harvesting_slips hs inner join harvesting_slip_details hsd 
    on hsd.harvesting_slip_id = hs.id inner join houses h 
    on h.id = hsd.house_id inner join flocks f 
    on f.id = hsd.flock_id 
 where hs.harvest_date <= '2023-10-31'

-- Weighings
SELECT 'WS-old-' || id::varchar as note_no, usage_date as note_date,
       feed_type as good_name,lorry as vehicle_no, gross, tare, unit
  FROM feed_usages
 where usage_date <= '2023-10-31'

--goods
select p.name1 as name,	p.unit,	p.description as descriptions,	sa.name1 as sales_account_name,
	     pa.name1 as purchase_account_name,	stc.code as sales_tax_code_name,
	     ptc.code as purchase_tax_code_name
from products p inner join accounts sa 
  on sa.id = p.sale_account_id inner join accounts pa 
  on pa.id = p.purchase_account_id inner join tax_codes stc 
  on stc.id = p.supply_tax_code_id inner join tax_codes ptc 
  on ptc.id = p.purchase_tax_code_id
group by p.id , sa.id, pa.id, stc.id, ptc.id
	order by 1

--good_packagings
select p.name1 as good_name, pp.pack_qty_name as name,	pp.quantity as unit_multiplier,
	     pp."cost" as cost_per_package
from products p inner join product_packagings pp 
  on pp.product_id = p.id inner join packagings p2 
  on p2.id = pp.packaging_id
	order by 1

 -- aging query
 with has_balance_contacts as (
	   select c.id, c.name
	     from contacts c inner join transactions t on c.id = t.contact_id 
	    where t.doc_date <= '2023-10-31'
	    group by c.id
	   having sum(t.amount) <> 0),
	 has_balance_txn as (
	   select t.doc_date, t.doc_type, t.doc_no, t.contact_id, c.name as contact_name,
	          t.amount + coalesce(sum(stm.match_amount), 0) + coalesce(sum(tm.match_amount), 0) as balance
         from transactions t inner join has_balance_contacts c 
           on c.id = t.contact_id left outer join seed_transaction_matchers stm 
           on stm.transaction_id = t.id left outer join transaction_matchers tm 
           on tm.transaction_id = t.id
        where t.contact_id is not null
          and t.doc_date <= '2023-10-31'
        group by t.id, c.name
        having t.amount + coalesce(sum(stm.match_amount), 0) + coalesce(sum(tm.match_amount), 0) <> 0
	 ),
	 has_balance_txn_1 as (
	 select hbt.doc_date, hbt.doc_type, hbt.doc_no, hbt.contact_id, hbt.contact_name, 
	        hbt.balance - coalesce(sum(stm.match_amount), 0) - coalesce(sum(tm.match_amount), 0) as balance
	   from has_balance_txn hbt left outer join seed_transaction_matchers stm 
	     on stm.m_doc_type = hbt.doc_type and stm.m_doc_id::varchar = hbt.doc_no left outer join transaction_matchers tm 
         on tm.doc_type = hbt.doc_type and tm.doc_id::varchar = hbt.doc_no 
	  group by hbt.doc_date, hbt.doc_type, hbt.doc_no, hbt.contact_id, hbt.contact_name, hbt.balance
	  having hbt.balance - coalesce(sum(stm.match_amount), 0) - coalesce(sum(tm.match_amount), 0)  <> 0)
	  
	    
	  
	  select contact_name, 
	         sum(case when 
                 extract(day from '2023-10-31'::timestamp - doc_date::timestamp) <= 30 then balance else 0 end) as day0,
	         sum(case when 
                 extract(day from '2023-10-31'::timestamp - doc_date::timestamp) <= 60 and
	               extract(day from '2023-10-31'::timestamp - doc_date::timestamp) > 30 then balance else 0 end) as day30,
	         sum(case when 
                 extract(day from '2023-10-31'::timestamp - doc_date::timestamp) <= 90 and 
	               extract(day from '2023-10-31'::timestamp - doc_date::timestamp) > 60 then balance else 0 end) as day60,
	         sum(case when 
                 extract(day from '2023-10-31'::timestamp - doc_date::timestamp) <= 120 and 
                 extract(day from '2023-10-31'::timestamp - doc_date::timestamp) > 90 then balance else 0 end) as day90,
          sum(case when 
                 extract(day from '2023-10-31'::timestamp - doc_date::timestamp) > 120 then balance else 0 end) as day120
	    from has_balance_txn_1 
	   group by contact_name;