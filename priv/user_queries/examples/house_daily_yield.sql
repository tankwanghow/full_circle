WITH params AS (
  SELECT '2026-01-01'::date AS from_date,
         '2026-08-20'::date AS to_date,
         'H01' AS house_no
),
datelist AS (
  SELECT generate_series(p.from_date, p.to_date, interval '1 day')::date AS gdate
  FROM params p
),
hf AS (
  SELECT DISTINCT m.house_id, m.flock_id, f.dob
  FROM fct_movements m
  JOIN fct_houses h ON h.id = m.house_id
  JOIN fct_flocks f ON f.id = m.flock_id
  CROSS JOIN params p
  WHERE h.house_no = upper(btrim(p.house_no))
),
lasthar AS (
  SELECT hf.flock_id, MAX(hv.har_date) AS last_har
  FROM hf
  JOIN fct_harvest_details hd ON hd.house_id = hf.house_id
  JOIN fct_harvests hv ON hv.id = hd.harvest_id
  WHERE hd.flock_id = hf.flock_id
  GROUP BY hf.flock_id
),
mvb AS (
  SELECT hf.flock_id, COALESCE(SUM(m.quantity), 0) AS qty
  FROM hf
  JOIN fct_movements m ON m.house_id = hf.house_id
  CROSS JOIN params p
  WHERE m.flock_id = hf.flock_id AND m.move_date < p.from_date
  GROUP BY hf.flock_id
),
mvd AS (
  SELECT hf.flock_id, m.move_date AS gdate, SUM(m.quantity) AS qty
  FROM hf
  JOIN fct_movements m ON m.house_id = hf.house_id
  CROSS JOIN params p
  WHERE m.flock_id = hf.flock_id
    AND m.move_date BETWEEN p.from_date AND p.to_date
  GROUP BY hf.flock_id, m.move_date
),
deb AS (
  SELECT hf.flock_id, COALESCE(SUM(hd.dea_1 + hd.dea_2), 0) AS dea
  FROM hf
  JOIN fct_harvest_details hd ON hd.house_id = hf.house_id
  JOIN fct_harvests hv ON hv.id = hd.harvest_id
  CROSS JOIN params p
  WHERE hd.flock_id = hf.flock_id AND hv.har_date < p.from_date
  GROUP BY hf.flock_id
),
hrd AS (
  SELECT hf.flock_id, hv.har_date AS gdate,
         SUM(hd.har_1 + hd.har_2 + hd.har_3) * 30 AS eggs,
         SUM(hd.dea_1 + hd.dea_2) AS dea
  FROM hf
  JOIN fct_harvest_details hd ON hd.house_id = hf.house_id
  JOIN fct_harvests hv ON hv.id = hd.harvest_id
  CROSS JOIN params p
  WHERE hd.flock_id = hf.flock_id
    AND hv.har_date BETWEEN p.from_date AND p.to_date
  GROUP BY hf.flock_id, hv.har_date
),
daily AS (
  SELECT hf.flock_id, hf.dob, dl.gdate,
         COALESCE(mvd.qty, 0) AS moved,
         COALESCE(hrd.eggs, 0) AS eggs,
         COALESCE(hrd.dea, 0) AS dea
  FROM hf
  CROSS JOIN datelist dl
  LEFT JOIN mvd ON mvd.flock_id = hf.flock_id AND mvd.gdate = dl.gdate
  LEFT JOIN hrd ON hrd.flock_id = hf.flock_id AND hrd.gdate = dl.gdate
),
running AS (
  SELECT d.gdate, d.eggs, lh.last_har,
         (date_part('day', d.gdate::timestamp - d.dob::timestamp) / 7)::integer AS age,
         COALESCE(mvb.qty, 0) + SUM(d.moved)
           OVER (PARTITION BY d.flock_id ORDER BY d.gdate
                 ROWS UNBOUNDED PRECEDING) AS cum_in,
         COALESCE(deb.dea, 0) + COALESCE(SUM(d.dea)
           OVER (PARTITION BY d.flock_id ORDER BY d.gdate
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS cum_dea
  FROM daily d
  LEFT JOIN mvb ON mvb.flock_id = d.flock_id
  LEFT JOIN deb ON deb.flock_id = d.flock_id
  LEFT JOIN lasthar lh ON lh.flock_id = d.flock_id
),
live AS (
  SELECT r.gdate, r.eggs, r.age, (r.cum_in - r.cum_dea) AS alive
  FROM running r
  WHERE (r.cum_in - r.cum_dea) > 0
    AND (COALESCE(r.last_har >= r.gdate, false)
         OR (r.last_har IS NULL AND r.age < 25))
)
SELECT l.gdate AS date,
       round(SUM(l.alive * l.age)::numeric / SUM(l.alive))::integer AS age_weeks,
       SUM(l.alive)::bigint AS alive,
       SUM(l.eggs)::bigint AS egg_produced,
       round(SUM(l.eggs)::numeric / SUM(l.alive), 4) AS egg_per_live_chicken
FROM live l
GROUP BY l.gdate
ORDER BY l.gdate
