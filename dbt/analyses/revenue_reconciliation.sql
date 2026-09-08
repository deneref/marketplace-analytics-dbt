-- Revenue reconciliation: orders_stats vs the marketplace's monthly realization report (delivered appendix).
-- Run with `dbt compile` and paste into Snowflake, or `dbt show --select revenue_reconciliation --limit 200`.
--
-- Hypothesis (2026-09-08): the seller is paid the price BEFORE the marketplace's own discounts, i.e.
-- realization.total_before_discount for delivered units. Four candidates from orders_stats are compared so the
-- data, not the docs, picks the revenue definition.
--
-- RESULT (run 2026-09-08, 20 months, 1 405 delivered orders, 0 orders missing on either side):
--   * price_buyer_total == realization.total_after_discount EXACTLY in every month — BUYER is what the buyer paid
--     after all discounts, Plus points included.
--   * price_buyer_total + price_marketplace_total ≈ realization.total_before_discount: −0.73 % overall,
--     0 … −2.5 % by month (exact 0 in two months). MARKETPLACE is therefore the marketplace-funded discount as a
--     whole, not just coupons as the docs say.
--   * buyer + cashback + SUBSIDY: −1.9 % overall, up to −5.6 % by month — worse. Cashback and coupon subsidies
--     are components of MARKETPLACE, not additions to it.
--   → revenue = price_buyer_total + price_marketplace_total. Residual −0.7 % is still unattributed: the
--     discount breakdown columns below are there to find it (Sber Spasibo, partial deliveries, ...).
--
-- Comparison unit: ORDER (subsidies exist only per order). Delivered units on the orders side are taken BEFORE
-- returns (units_ordered − units_rejected): the realization "delivered" appendix lists what was delivered, returns
-- are a separate appendix. Line prices are per line, so a partially delivered line is scaled by delivered share.
--
-- Three result blocks, switch with the `block` filter at the bottom:
--   'monthly'  — totals by delivery month, all candidates, absolute and % gap
--   'orders'   — worst 50 orders by gap on the best candidate
--   'dates'    — does date(status_updated_at) of a DELIVERED order match realization.delivered_date?

with realization as (

    select
        order_id,
        min(delivered_date)                                         as delivered_date,
        min(report_month)                                           as report_month,
        sum(event_units)                                            as units_delivered,
        sum(event_units * price_before_discount)                    as amount_before_discount,   -- per-unit price × units
        sum(total_before_discount)                                  as total_before_discount,    -- report's own line total
        sum(total_after_discount)                                   as total_after_discount,
        sum(event_units * discount_marketplace_promo)               as discount_promo,
        sum(event_units * discount_sber_spasibo)                    as discount_sber,
        sum(event_units * discount_yandex_plus)                     as discount_plus
    from {{ ref('stg_ym__realization_lines') }}
    where event_type = 'delivered'
    group by 1

),

lines as (

    select
        order_id,
        order_status,
        status_updated_at,
        sum(units_ordered - units_rejected)                         as units_delivered_before_returns,
        -- scale line money by the delivered share (partial deliveries)
        sum(price_buyer_total    * div0(units_ordered - units_rejected, units_ordered))     as buyer_total,
        sum(cashback_total       * div0(units_ordered - units_rejected, units_ordered))     as cashback_total,
        sum(price_marketplace_total * div0(units_ordered - units_rejected, units_ordered))  as marketplace_total
    from {{ ref('int_order_lines') }}
    where order_status in ('DELIVERED', 'PARTIALLY_DELIVERED')
       or units_returned > 0                    -- returned after delivery: status may still say DELIVERED, keep anyway
    group by 1, 2, 3

),

subsidies as (

    select
        o.order_id,
        sum(iff(s.value:type = 'SUBSIDY',         iff(s.value:operationType = 'DEDUCTION', -1, 1) * s.value:amount::number(18, 2), 0)) as subsidy_coupons,
        sum(iff(s.value:type = 'YANDEX_CASHBACK', iff(s.value:operationType = 'DEDUCTION', -1, 1) * s.value:amount::number(18, 2), 0)) as subsidy_cashback,
        sum(iff(s.value:type = 'DELIVERY',        iff(s.value:operationType = 'DEDUCTION', -1, 1) * s.value:amount::number(18, 2), 0)) as subsidy_delivery
    from {{ ref('stg_ym__orders') }} as o,
        lateral flatten(input => o.subsidies_json, outer => true) as s
    group by 1

),

per_order as (

    select
        coalesce(r.order_id, l.order_id)                            as order_id,
        r.report_month,
        r.delivered_date,
        l.order_status,
        l.status_updated_at::date                                   as status_updated_date,
        r.units_delivered                                           as units_realization,
        l.units_delivered_before_returns                            as units_orders,
        r.total_before_discount                                     as realization_before_discount,
        r.total_after_discount                                      as realization_after_discount,
        r.discount_promo,
        r.discount_sber,
        r.discount_plus,
        l.buyer_total                                               as cand_buyer,
        l.marketplace_total                                         as marketplace_total,
        l.buyer_total + coalesce(l.cashback_total, 0)               as cand_buyer_cashback,
        l.buyer_total + coalesce(l.cashback_total, 0)
            + coalesce(s.subsidy_coupons, 0)                        as cand_buyer_cashback_coupons,
        l.buyer_total + coalesce(l.marketplace_total, 0)            as cand_buyer_marketplace,
        s.subsidy_coupons,
        s.subsidy_cashback,
        s.subsidy_delivery
    from realization as r
    full outer join lines as l
        on l.order_id = r.order_id
    left join subsidies as s
        on s.order_id = coalesce(r.order_id, l.order_id)

),

monthly as (

    select
        'monthly'                                                   as block,
        coalesce(report_month, to_char(status_updated_date, 'YYYY-MM')) as month,
        count(*)                                                    as orders,
        count_if(realization_before_discount is null)               as orders_missing_in_realization,
        count_if(cand_buyer is null)                                as orders_missing_in_orders_stats,
        sum(realization_before_discount)                            as realization_before_discount,
        sum(realization_after_discount)                             as realization_after_discount,
        sum(cand_buyer)                                             as cand_buyer,
        sum(cand_buyer_cashback)                                    as cand_buyer_cashback,
        sum(cand_buyer_cashback_coupons)                            as cand_buyer_cashback_coupons,
        sum(cand_buyer_marketplace)                                 as cand_buyer_marketplace,
        sum(discount_promo)                                         as discount_promo,
        sum(discount_sber)                                          as discount_sber,
        sum(discount_plus)                                          as discount_plus,
        sum(marketplace_total)                                      as marketplace_total,
        -- where does the residual of the winning candidate go? if this is ~0, Sber Spasibo is not compensated
        round(100 * div0(sum(cand_buyer_marketplace) - (sum(realization_before_discount) - sum(discount_sber)),
                         sum(realization_before_discount)), 2)      as gap_pct_buyer_marketplace_ex_sber,
        round(100 * div0(sum(cand_buyer)                  - sum(realization_before_discount), sum(realization_before_discount)), 2) as gap_pct_buyer,
        round(100 * div0(sum(cand_buyer_cashback)         - sum(realization_before_discount), sum(realization_before_discount)), 2) as gap_pct_buyer_cashback,
        round(100 * div0(sum(cand_buyer_cashback_coupons) - sum(realization_before_discount), sum(realization_before_discount)), 2) as gap_pct_buyer_cashback_coupons,
        round(100 * div0(sum(cand_buyer_marketplace)      - sum(realization_before_discount), sum(realization_before_discount)), 2) as gap_pct_buyer_marketplace
    from per_order
    group by 1, 2

),

orders_gap as (

    select
        'orders'                                                    as block,
        order_id,
        report_month,
        order_status,
        units_realization,
        units_orders,
        realization_before_discount,
        cand_buyer,
        cand_buyer_marketplace,
        cand_buyer_cashback_coupons,
        discount_promo,
        discount_sber,
        discount_plus,
        subsidy_coupons,
        subsidy_cashback,
        cand_buyer_marketplace - realization_before_discount        as gap
    from per_order
    where abs(coalesce(cand_buyer_marketplace, 0) - coalesce(realization_before_discount, 0)) > 1
    order by abs(gap) desc
    limit 50

),

dates as (

    select
        'dates'                                                     as block,
        order_status,
        datediff(day, delivered_date, status_updated_date)          as days_status_minus_delivered,
        count(*)                                                    as orders
    from per_order
    where delivered_date is not null and status_updated_date is not null
    group by 1, 2, 3
    order by 2, 3

)

select * from monthly order by month
-- select * from orders_gap
-- select * from dates
