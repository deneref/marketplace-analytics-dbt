{{ config(materialized='view') }}

-- Staging rule: rename, cast, UNNEST. No joins to other sources, no aggregation across records.
-- Grain: order × array index. RAW has one row per order with ITEMS as a JSON array;
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

payments as (

    select
        o.id::varchar                                                    as order_id,
        p.index::integer                                                 as payment_index,
        {{ dbt_utils.generate_surrogate_key(['o.id', 'p.value:id']) }}      as order_payment_key,
        p.value:id::varchar                                              as payment_id,
        p.value:type::varchar                                            as payment_type,      -- PAYMENT | REFUND
        p.value:source::varchar                                          as payment_source,    -- BUYER | SPLIT
        p.value:total::number(18, 2)                                     as payment_amount,
        p.value:date::date                                               as payment_date,
        p.value:paymentOrder:id::varchar                                 as payout_id,         -- null until paid out
        p.value:paymentOrder:date::date                                  as payout_date,
        o._loaded_at::timestamp_ntz                                      as _loaded_at,
        o._source_file::varchar                                          as _source_file
    from latest as o,
        lateral flatten(input => parse_json(o.payments)) as p

)

select * from payments
