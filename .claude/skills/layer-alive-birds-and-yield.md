---
name: layer-alive-birds-and-yield
description: Use when computing live bird counts, egg production, bird age, or lay rate (egg per bird) for layer houses - harvest reports, feed planning, saved queries over movements/harvest_details, or anything that divides eggs by "alive". Covers the per-flock rule and the phantom-flock guard that a plain house-level SUM gets wrong.
---

# Layer: alive birds and egg yield

Reference implementation: `FullCircle.Layer.harvest_report/2` in `lib/full_circle/layer.ex`.
A worked saved query is `priv/user_queries/examples/house_daily_yield.sql`.

## The two source tables

| Table | Carries |
|-------|---------|
| `movements` | `quantity` per (house, flock, `move_date`). Positive = placed, negative = sold/culled. Company-scoped. |
| `harvest_details` | `har_1/har_2/har_3` (trays collected) and `dea_1/dea_2` (deaths) per (house, flock). Date lives on the parent `harvests.har_date`. No `company_id` - always join through `harvests`. |

## Formulas

```
alive(flock, d)  = SUM(movements.quantity WHERE move_date <= d)
                 - SUM(dea_1 + dea_2      WHERE har_date  <  d)

eggs(flock, d)   = SUM(har_1 + har_2 + har_3) * 30      -- trays -> eggs

age(flock, d)    = (date_part('day', d::timestamp - flocks.dob::timestamp) / 7)::integer

lay rate(d)      = eggs(d) / alive(d)
```

Age is in weeks off `flocks.dob`, and `::integer` rounds rather than truncates, so a
flock reads "15 weeks" from day 105 onward. Pullets arrive around week 15 and reach
point of lay near week 19.

Deaths are counted **strictly before** `d`. Birds that died on day `d` were alive and
laying for part of it, so they stay in the denominator. `harvest_report/2` does this
deliberately, so a per-house daily yield matches the Harvest Report screen exactly.

Two places use the inclusive cut-off `har_date <= d` instead, and both are right for
what they do. `house_feed_type_query/6` feeds only the birds that will actually eat.
The saved query "Eggs Production" sums deaths with a running
`SUM(dea) OVER (PARTITION BY flock_id ORDER BY har_date)`, which includes the current
day. The gap is about 0.1% of the flock, but it is enough that two reports of the same
day will not tie out to the last egg. Say which convention a new report follows.

## Per flock, then aggregate. Never sum the house first.

**Compute `alive` per (house, flock), drop the flocks that are not really there, and
only then aggregate to the house.** A house holds many flocks over its life and the
retired ones do not reliably net to zero.

Most retired flocks land exactly on `alive = 0`, because the closing "SOLD" movement
cancels the placement. Two failure modes break that:

- **Negative residue.** Deaths keep being recorded after the flock was sold out.
  House 001 flock 20230927-203 sits at `-547`. Summed at house level it eats into the
  live flock: house 001 on 2026-08-20 reads **2617** birds instead of **3164**, turning
  a 0.79 lay rate into an implausible 0.95.
- **Positive residue.** The closing movement undercounted, so birds are never removed.
  House 002 flock 20180220-114 was sold in December 2019 and still shows 585 birds.

Filtering `alive > 0` per flock handles the first. It does **not** handle the second.

## Phantom flocks: guard on harvest activity, not on age

As of the 2026-08 dev restore, **54 flocks across 49 houses** carry a positive residue
they should not, **11614 phantom birds** farm-wide, and 7 of those flocks were never
harvested at all. Left in, house 002 reports 3652 birds at a bird-weighted age of 129
weeks, a figure describing neither flock present, and a lay rate of 0.65 instead of
the true 0.77. `priv/user_queries/examples/phantom_flocks.sql` lists them, and is
saved for the company as "Phantom Flock Audit".

A flock that is really in the house gets harvested every day, so test that:

```sql
AND (COALESCE(last_har >= gdate, false) OR (last_har IS NULL AND age < 25))
-- last_har = MAX(harvests.har_date) per flock, over all history
```

**Wrap the comparison in `COALESCE`.** For a never-harvested flock `last_har >= gdate`
is NULL, not false. In a `WHERE` that still excludes the row, so the yield query is
right either way, but the moment you invert the condition to audit for phantoms,
`NOT (NULL OR false)` is NULL and every never-harvested flock drops out of the audit
silently. That hid 7 flocks and 5764 birds on the first pass, including the single
largest phantom, house 051 at 2454 birds.

The first arm keeps flocks still being harvested, including the pre-lay weeks of a
flock placed earlier in the range, whose `last_har` lies in the future relative to
those rows. The second arm keeps a flock placed so recently it has never been
harvested at all - house G03 in August 2026 is 16000 birds at 13 weeks with no
harvest yet, and it must not vanish.

**The `IS NULL` arm needs the age bound.** Without it, never-harvested phantoms
survive forever: house 025 carries flock 20150812-65 at 1836 birds and 575 weeks, and
house C55 is two 2018 flocks and nothing else. The 25-week bound sits well past point
of lay at 19 and far below any phantom, which start around 300 weeks.

Once phantoms are gone, no house in this data holds two genuinely live flocks at once.
Summing the survivors is still the correct shape, and if it ever does happen, weight
age by bird count so it degenerates to the exact flock age in the single-flock case.

## Days with no birds

Both filters together also drop the gap between flocks, when the house is cleared and
the next batch is not yet placed. Those dates simply produce no row. A freshly placed
flock shows `alive > 0` with `eggs = 0` for about four weeks, which is correct.

`harvest_report/2` reaches roughly the same protection a blunter way, by bounding age
to 14..109 weeks. That also hides the weeks right after placement, so do not copy that
bound into a report meant to show the pre-lay period.

## Saved-query shape

Saved queries have no parameter binding (see [[user-query-sql]]), so `from_date`,
`to_date` and `house_no` sit in a leading `params` CTE that the user edits before
executing. Keep lines short and comments out of the SQL: a long paste into the query
textarea can silently lose characters mid-token.
