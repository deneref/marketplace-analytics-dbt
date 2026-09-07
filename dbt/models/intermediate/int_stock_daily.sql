-- Stock of one SKU at one warehouse on one day, stock types as columns.
-- Grain: snapshot_date × sku × warehouse_id — one row per pair listed at the warehouse that day.
--
-- Why a pivot: stg_ym__stock_levels is long (one row per stock type) and the types are NOT additive —
-- FIT = AVAILABLE + FREEZE (sellable + reserved for orders), DEFECT and QUARANTINE are separate piles. A plain
-- sum over types double-counts the good stock; columns make the arithmetic explicit and impossible to get
-- wrong downstream. An offer with an empty stocks array comes from staging as one row with stock_type NULL and
-- units 0 — it survives the group by as a row of zeros, which is how fct_inventory_daily sees a stock-out.
-- No calendar fill: a day without a snapshot is simply absent.

{#- stock types → column names (getStocks WarehouseStockType). EXPIRED and UTILIZATION do not occur for apparel;
    add a type here when the accepted_values test on stg_ym__stock_levels warns about a new one. -#}
{% set stock_type_columns = {
    'AVAILABLE':                 'units_available',
    'FREEZE':                    'units_freeze',
    'FIT':                       'units_fit',
    'QUARANTINE':                'units_quarantine',
    'UTILIZATION':               'units_utilization',
    'DEFECT':                    'units_defect',
    'UTILIZATION':               'units_utilization'
} %}

with stock_types as (

    -- one row per sku × warehouse × day: units of each stock type as a column, 0 when the type is absent
    select
        sku,
        snapshot_date,
        warehouse_id,
        {% for stock_type, col in stock_type_columns.items() -%}
        sum(iff(stock_type = '{{ stock_type }}', units, 0))        as {{ col }},
        {% endfor -%}
        max(stock_updated_at) as stock_updated_at
    from {{ ref('stg_ym__stock_levels') }}
    group by sku, snapshot_date, warehouse_id

),

final as (

    select
        sku,
        warehouse_id,
        snapshot_date,
        {% for stock_type, col in stock_type_columns.items() -%}
        {{ col }},
        {% endfor -%}
        stock_updated_at,
        units_available = 0                                         as is_out_of_stock   -- nothing sellable right now; FIT may still be > 0 (all reserved)
    from stock_types

)

select * from final
