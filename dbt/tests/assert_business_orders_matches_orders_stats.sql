-- The two order sources must describe the same orders. business_orders is the newer one (it carries the cancellation
-- reason and the real delivery date), orders_stats is the reconciled one (money, fine-grained status, per-unit
-- events), and the loss reason downstream is built by joining them — so a drift between them silently changes the
-- answer instead of breaking anything.
--
-- Three checks, all at WARN, because the two sources are snapshots taken on their own schedules:
--   * coverage — an order in orders_stats with no row here. This is the one that matters: such an order loses its
--     reason and falls into the default branch of the tree, so the reason mix shifts without any number looking
--     wrong. It is also the only alarm for a stale backfill (the endpoint has no scheduled catch-up yet), which is
--     why there is no source freshness on business_orders — a manual backfill would warn on every run and be ignored.
--   * ordered_date — the immutable fact both sources state. A mismatch means the join key lines up rows that are not
--     the same order, or one side changed its timezone handling.
--   * attributes — payment_type and is_test_order. Expected noise, documented: orders_stats reports the payment type
--     of some cancelled orders as UNKNOWN, so exactly one order differs today.
-- Error severity is wrong for all three: the daily job builds staging, and orders_stats is refreshed weekly while
-- business_orders is pulled by hand — a gap is a to-do, not a broken pipeline. When the catch-up is scheduled,
-- coverage should be promoted to error.

{{ config(severity='warn') }}

with orders_stats as (

    select order_id, ordered_date, payment_type, is_test_order
    from {{ ref('stg_ym__orders') }}

),

business_orders as (

    select
        order_id,
        {{ moscow_date('ordered_at') }}     as ordered_date,
        payment_type,
        is_test_order
    from {{ ref('stg_ym__business_orders') }}

),

coverage as (

    select
        'coverage'                          as check_name,
        o.order_id,
        'missing in business_orders'        as detail
    from orders_stats as o
    left join business_orders as b
        on b.order_id = o.order_id
    where b.order_id is null

),

ordered_date_mismatch as (

    select
        'ordered_date'                      as check_name,
        o.order_id,
        o.ordered_date::varchar || ' vs ' || b.ordered_date::varchar    as detail
    from orders_stats as o
    join business_orders as b
        on b.order_id = o.order_id
    where b.ordered_date is distinct from o.ordered_date

),

attribute_mismatch as (

    select
        'attributes'                        as check_name,
        o.order_id,
        'payment_type ' || coalesce(o.payment_type, 'null') || ' vs ' || coalesce(b.payment_type, 'null')
            || ', is_test_order ' || coalesce(o.is_test_order::varchar, 'null') || ' vs ' || coalesce(b.is_test_order::varchar, 'null')
                                            as detail
    from orders_stats as o
    join business_orders as b
        on b.order_id = o.order_id
    where b.payment_type is distinct from o.payment_type
       or b.is_test_order is distinct from o.is_test_order

)

select * from coverage
union all
select * from ordered_date_mismatch
union all
select * from attribute_mismatch
