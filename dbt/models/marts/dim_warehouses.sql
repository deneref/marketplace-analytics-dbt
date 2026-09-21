-- One row per marketplace (FBY) warehouse ever listed by GET v2/warehouses — the names, places and roles behind
-- warehouse_id in fct_order_lines (where the parcel shipped from) and fct_inventory_daily (where the stock sits).
-- Grain: warehouse_id. Two inputs: the marketplace's own list (stg_ym__warehouses, latest pull wins, a warehouse
-- that left the list keeps its last row with is_current = false) and the seller's seed warehouse_attributes for what
-- the list does not say — the turnover cluster the warehouse reports under and its role. The role matters for stock:
-- units at a returns warehouse are parcels on their way back, not what a buyer can order, so rpt_stock_days counts
-- "in stock" over is_return_warehouse = false only. first_/last_stock_report_date come from the stock report and
-- tell whether the warehouse has ever held our goods (8 of 13 have). Table, 13 rows.

{{ config(materialized='table') }}

with warehouses as (

    select *
    from {{ ref('stg_ym__warehouses') }}

),

attributes as (

    select *
    from {{ ref('warehouse_attributes') }}

),

stock_history as (

    -- days the stock report listed the warehouse (with or without units)
    select
        warehouse_id,
        min(snapshot_date)                              as first_stock_report_date,
        max(snapshot_date)                              as last_stock_report_date
    from {{ ref('int_stock_daily') }}
    where warehouse_id is not null
    group by warehouse_id

),

final as (

    select
        -- key
        w.warehouse_id,

        -- as the marketplace lists it
        w.warehouse_name,                                            -- the name the stock report prints
        w.city,
        w.street,
        w.latitude,
        w.longitude,
        w.is_current,                                                -- present in the latest GET v2/warehouses
        w.last_seen_date,

        -- as the seller classifies it (seed)
        a.cluster_name,                                              -- NULL until the seed has the row (warn)
        coalesce(a.warehouse_role, 'unknown')                        as warehouse_role,
        coalesce(a.warehouse_role = 'returns', false)                as is_return_warehouse,
        a.sort_order,

        -- our goods there
        s.first_stock_report_date,
        s.last_stock_report_date,
        s.warehouse_id is not null                                   as has_stock_history,

        current_timestamp()                                          as dbt_updated_at
    from warehouses as w
    left join attributes as a
        on a.warehouse_id = w.warehouse_id
    left join stock_history as s
        on s.warehouse_id = w.warehouse_id

)

select * from final
