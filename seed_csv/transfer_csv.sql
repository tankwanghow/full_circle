

-- Accounts
-- Try to get all the General Ledger Account to the new system

SELECT at2."name" as account_type, a.name1 as name, a.description
  from accounts a inner join account_types at2 
    on a.account_type_id = at2.id
 where true
   and at2.dotted_ids ilike '1.8%' 
 order by 2

 -- Contacts
 -- Is all the Trade Debtors, Creditors, Transport Agents, Other Debtors and Other Creditors Accounts
 -- Grab these data with addresses


 ----!!!!  MAKE SURE CONTACT AND ACCOUNT ARE UP-TO-DATE BEFORE SEEDING TRANSACTIONS !!!!!----

-- FixedAssets
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
  