-- Stock of one SKU at one warehouse at the end of one day, stock buckets as columns.
-- Grain: snapshot_date × sku × warehouse_name — one row per pair the report listed at the warehouse that day.
--
-- Why a pivot: stg_ym__stock_levels is long (one row per stock bucket) and the buckets are NOT additive —
-- FIT = AVAILABLE + FREEZE (sellable + reserved for orders), DEFECT and QUARANTINE are separate piles. A plain
-- sum over buckets double-counts the good stock; columns make the arithmetic explicit and impossible to get
-- wrong downstream. A SKU listed at a warehouse with every bucket 0 comes from staging as one row with stock_type
-- NULL and units 0 — it survives the group by as a row of zeros, which is how fct_inventory_daily sees a stock-out.
-- No calendar fill: a day without a report is simply absent (re-request it: `--report stocks-report --date <day>`).
--
-- Warehouse id: the report names warehouses, orders use ids. The name is the native key of this model (a row can
-- never be lost to a missing mapping); warehouse_id is resolved from stg_ym__warehouses and is NULL for a name the
-- marketplace no longer lists (assert_stock_warehouses_resolve warns which ones). Since 2026-09-14 (report instead of
-- the JSON snapshot). sku is the seller's code (staging takes it from the report's ARTICLE column); the warehouse label
-- (K4) rides along as reported_sku. Should the report ever print one article under two labels at one warehouse on one
-- day (a label change), the buckets are summed and the smaller label is kept — the grain stays sku × warehouse × day.

{#- stock buckets → column names (the JSON endpoint's WarehouseStockType vocabulary, kept by stg_ym__stock_levels) -#}
{% set stock_type_columns = {
    'AVAILABLE':   'units_available',
    'FREEZE':      'units_freeze',
    'FIT':         'units_fit',
    'QUARANTINE':  'units_quarantine',
    'DEFECT':      'units_defect',
    'EXPIRED':     'units_expired',
    'UTILIZATION': 'units_utilization'
} %}

with stock_buckets as (

    -- one row per sku × warehouse × day: units of each bucket as a column, 0 when the bucket is absent
    select
        sku,
        snapshot_date,
        warehouse_name,
        min(reported_sku)                                           as reported_sku,
        {% for stock_type, col in stock_type_columns.items() -%}
        sum(iff(stock_type = '{{ stock_type }}', units, 0))        as {{ col }},
        {% endfor -%}
        max(_loaded_at)                                             as _loaded_at
    from {{ ref('stg_ym__stock_levels') }}
    group by sku, snapshot_date, warehouse_name

),

warehouses as (

    select warehouse_id, warehouse_name
    from {{ ref('stg_ym__warehouses') }}

),

final as (

    select
        s.sku,
        s.reported_sku,
        s.warehouse_name,
        w.warehouse_id,                                             -- NULL when the name is not in GET v2/warehouses (closed warehouse)
        s.snapshot_date,
        {% for stock_type, col in stock_type_columns.items() -%}
        s.{{ col }},
        {% endfor -%}
        s.units_available = 0                                       as is_out_of_stock,    -- nothing sellable; FIT may still be > 0 (all reserved)
        s._loaded_at
    from stock_buckets as s
    left join warehouses as w
        on w.warehouse_name = s.warehouse_name

)

select * from final
