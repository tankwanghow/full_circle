WITH params AS (
  SELECT '2026-08-20'::date AS as_of
),
mv AS (
  SELECT m.house_id, m.flock_id, SUM(m.quantity) AS q, MAX(m.move_date) AS last_mv
  FROM fct_movements m
  CROSS JOIN params p
  WHERE m.move_date <= p.as_of
  GROUP BY m.house_id, m.flock_id
),
de AS (
  SELECT hd.house_id, hd.flock_id, SUM(hd.dea_1 + hd.dea_2) AS d
  FROM fct_harvest_details hd
  JOIN fct_harvests hv ON hv.id = hd.harvest_id
  CROSS JOIN params p
  WHERE hv.har_date < p.as_of
  GROUP BY hd.house_id, hd.flock_id
),
lh AS (
  SELECT hd.house_id, hd.flock_id, MAX(hv.har_date) AS last_har
  FROM fct_harvest_details hd
  JOIN fct_harvests hv ON hv.id = hd.harvest_id
  GROUP BY hd.house_id, hd.flock_id
),
resid AS (
  SELECT h.house_no, f.flock_no, f.dob,
         (date_part('day', p.as_of::timestamp - f.dob::timestamp) / 7)::integer AS age_weeks,
         (mv.q - COALESCE(de.d, 0))::integer AS residual,
         lh.last_har, mv.last_mv
  FROM mv
  LEFT JOIN de ON de.house_id = mv.house_id AND de.flock_id = mv.flock_id
  LEFT JOIN lh ON lh.house_id = mv.house_id AND lh.flock_id = mv.flock_id
  JOIN fct_houses h ON h.id = mv.house_id
  JOIN fct_flocks f ON f.id = mv.flock_id
  CROSS JOIN params p
  WHERE mv.q - COALESCE(de.d, 0) > 0
)
SELECT house_no, flock_no, dob, age_weeks, residual, last_har, last_mv
FROM resid r
CROSS JOIN params p
WHERE NOT (COALESCE(r.last_har >= p.as_of, false)
           OR (r.last_har IS NULL AND r.age_weeks < 25))
ORDER BY residual DESC, house_no
