# Desk Trip Assembly Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let operators check open sales + supply/warehouse rows on the Trading Desk and open a prefilled trip modal.

**Architecture:** LiveView selection state (good lock + MapSets) filters panel rows; pure helper builds trip attrs; existing `TripFormComponent` accepts optional `prefill` map.

**Tech Stack:** Phoenix LiveView, Ecto, existing `FullCircle.Trading` APIs.

**Spec:** `docs/superpowers/specs/2026-07-17-desk-trip-assembly-design.md`

## Global Constraints

- No new DB tables
- Multi sales + multi sources; either side first
- Good lock from first check
- Create Trip requires ≥1 source and ≥1 sales
- Prefill uses undelivered / remaining / on hand; imbalance warn-only
- Clear selection after successful trip save

---

### Task 1: `build_trip_attrs_from_selection/3`

**Files:**
- Modify: `lib/full_circle/trading.ex`
- Test: `test/full_circle/trading/trip_assembly_test.exs`

**Produces:** `Trading.build_trip_attrs_from_selection(selection, company, user) :: {:ok, attrs} | {:error, reason}`

Selection map keys: `:good_id`, `:supply_ids`, `:warehouse_keys` (list of `%{location_id, good_id}`), `:sales_ids`.

- [ ] Unit test with 1 sales + 1 warehouse + 1 supply
- [ ] Implement helper (loads, drops, good, date, transport_mode)
- [ ] Commit

### Task 2: Desk selection + good lock + tray + checkboxes

**Files:**
- Modify: `lib/full_circle_web/live/trading_desk_live/index.ex`
- Test: `test/full_circle_web/live/trading_desk_live_test.exs`

- [ ] Selection assigns; toggle/clear events
- [ ] Good lock in apply_filters; hide zero warehouse when locked
- [ ] Checkbox UI + selection tray
- [ ] LiveView tests
- [ ] Commit

### Task 3: Prefill trip modal

**Files:**
- Modify: `lib/full_circle_web/live/trading_desk_live/trip_form_component.ex`
- Modify: desk `index.ex` Create Trip handler
- Test: desk live test multi select → form fields

- [ ] TripFormComponent `prefill` assign
- [ ] Create Trip builds attrs, opens modal
- [ ] Clear selection on trip save
- [ ] Commit
