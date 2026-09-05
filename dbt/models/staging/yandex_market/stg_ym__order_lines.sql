{{ config(materialized='view') }}

-- Staging rule: rename, cast, UNNEST. No joins to other sources, no aggregation across records.
-- Grain: order × line (position in ITEMS). RAW has one row per order with ITEMS as a JSON array;
-- lateral flatten turns each element into a row. Order-level fields (status, payment type, region)
-- live in stg_ym__orders — join them in intermediate, not here.

with src as (

    select * from {{ source_or_seed('orders_stats') }}

),

latest as (

    -- the same quarter can be exported more than once: keep the latest load per ORDER,
    -- and do it BEFORE flattening — after flattening every line of a re-exported order would survive
    select *
    from src
    qualify row_number() over (partition by id order by _loaded_at desc) = 1

),

lines as (

    select
        o.id                                    as order_id,
        i.index                                 as line_index,      -- position in the array: 0, 1, 2 …
        i.value                                 as item,            -- VARIANT: one element of ITEMS
        o._loaded_at,
        o._source_file
    from latest as o,
        lateral flatten(input => parse_json(o.items)) as i

),

-- prices is a nested array [{type: BUYER|MARKETPLACE|CASHBACK, costPerItem, total}];
-- a second flatten + conditional aggregation pivots it into columns without multiplying lines
prices as (

    select
        l.order_id,
        l.line_index,
        max(iff(p.value:type = 'BUYER',       p.value:total,       null))::number(18, 2) as price_buyer_total,
        max(iff(p.value:type = 'MARKETPLACE', p.value:total,       null))::number(18, 2) as price_marketplace_total,
        max(iff(p.value:type = 'CASHBACK',    p.value:total,       null))::number(18, 2) as cashback_total,
        max(iff(p.value:type = 'BUYER',       p.value:costPerItem, null))::number(18, 2) as price_buyer_per_item
    from lines as l,
        lateral flatten(input => l.item:prices) as p
    group by 1, 2

),

renamed as (

    select
        l.order_id::varchar                                                     as order_id,
        l.line_index::integer                                                   as line_index,
        {{ dbt_utils.generate_surrogate_key(['l.order_id', 'l.line_index']) }}  as order_line_key,
        l.item:shopSku::varchar                                                 as sku,
        l.item:marketSku::varchar                                               as market_sku,
        l.item:offerName::varchar                                               as product_name,
        l.item:count::integer                                                   as units_ordered,
        l.item:warehouse:id::integer                                            as warehouse_id,
        l.item:warehouse:name::varchar                                          as warehouse_name,
        l.item:bidFee::number(18, 2)                                            as bid_fee,
        p.price_buyer_per_item,
        p.price_buyer_total,
        p.price_marketplace_total,
        p.cashback_total,
        l.item:details                                                          as details_json,   -- unnested separately in stg_ym__order_line_events
        l._loaded_at::timestamp_ntz                                             as _loaded_at,
        l._source_file::varchar                                                 as _source_file
    from lines as l
    left join prices as p
        on p.order_id = l.order_id
       and p.line_index = l.line_index

)

select * from renamed
