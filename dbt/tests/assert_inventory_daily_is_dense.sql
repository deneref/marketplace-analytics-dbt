-- The grid promise: on every report day, every sku × warehouse pair that had appeared by then has exactly one row.
-- A day with fewer rows than active pairs means the fill broke (a duplicate would already fail the unique key).
-- Returns one row per report day whose row count differs from the number of pairs alive that day.
{{ config(severity='error') }}

with pairs as (

    select
        sku,
        warehouse_id,
        min(snapshot_date)                          as first_seen_date
    from {{ ref('fct_inventory_daily') }}
    where is_reported
    group by sku, warehouse_id

),

days as (

    select distinct snapshot_date
    from {{ ref('fct_inventory_daily') }}

),

expected as (

    select
        d.snapshot_date,
        count(*)                                    as pairs_alive
    from days as d
    inner join pairs as p
        on p.first_seen_date <= d.snapshot_date
    group by d.snapshot_date

),

actual as (

    select
        snapshot_date,
        count(*)                                    as rows_in_fact
    from {{ ref('fct_inventory_daily') }}
    group by snapshot_date

)

select
    e.snapshot_date,
    e.pairs_alive,
    a.rows_in_fact
from expected as e
inner join actual as a
    on a.snapshot_date = e.snapshot_date
where a.rows_in_fact <> e.pairs_alive
