-- Daily sales: the one table a dashboard page reads.
-- Grain: delivered_date × sku — the day the buyer received the goods, no warehouse.
-- This is an AGGREGATE of fct_order_lines, nothing more: one group by, no joins, no new formulas. Every column here
-- is a sum of the same column there under the same filter (tests/assert_sales_daily_sums_to_order_lines.sql), so the
-- definition of "a sale" lives in exactly one place — the filter below:
--   * delivered_date is not null — received by the buyer; in-flight lines (PROCESSING / DELIVERY / PICKUP) carry
--     forecast units but no date and no money, and would otherwise form a null-date group;
--   * units_delivered > 0 — something was actually kept; fully unredeemed and fully returned lines drop out,
--     and with them their fees: contribution_margin here is the margin of what was SOLD, not the seller's P&L.
--     The cost of невыкуп lives in fct_order_lines (negative margin, no revenue) and is a different date basis;
--   * not is_test_order — the marketplace's test orders are not sales.
-- Not here on purpose: price_* as ordered (a line's ordered price is not a measure of its delivered units — revenue
-- is the delivered share), names and categories (dim_products via reporting), ratios (margin %, fee share — BI
-- divides the sums), days without sales (sparse table, BI fills zeros).
-- Table, not incremental: fct_order_lines is restated on returns and repriced on a cost reload, and the whole
-- aggregate rebuilds in seconds.

{{ config(materialized='table') }}

with lines as (

    select *
    from {{ ref('fct_order_lines') }}
    where delivered_date is not null
      and units_delivered > 0
      and not coalesce(is_test_order, false)

),

daily as (

    select
        {{ dbt_utils.generate_surrogate_key(['delivered_date', 'sku']) }}   as sales_daily_key,
        delivered_date,
        sku,

        -- orders that contained this sku on this day. NOT additive across skus: an order with two skus is counted
        -- once per sku. "Orders per day" = count(distinct order_id) over fct_order_lines in BI.
        count(distinct order_id)                                    as sku_orders_count,
        count(*)                                                    as lines_count,

        -- units
        sum(units_delivered)                                        as units_delivered,

        -- money, all RUB, all recognised on delivered_date (restated on returns)
        sum(revenue)                                                as revenue,

        -- fees allocated to the lines (positive = charged, negative = reversal)
        sum(fee_commission)                                         as fee_commission,
        sum(fee_delivery)                                           as fee_delivery,
        sum(fee_boost)                                              as fee_boost,
        sum(fee_payment_transfer)                                   as fee_payment_transfer,
        sum(fee_agency)                                             as fee_agency,
        sum(fee_crossregional)                                      as fee_crossregional,
        sum(fee_return_processing)                                  as fee_return_processing,
        sum(fee_loyalty)                                            as fee_loyalty,
        sum(fee_total)                                              as fee_total,
        sum(bid_fee)                                                as bid_fee,           -- reported on the line, not part of fee_total

        -- cost of goods and contribution
        sum(cogs)                                                   as cogs,
        sum(cogs_estimated)                                         as cogs_estimated,    -- the part of cogs on a planned cost; share = cogs_estimated / cogs in BI
        sum(contribution_margin)                                    as contribution_margin,

        current_timestamp()                                         as dbt_updated_at

    from lines
    group by delivered_date, sku

)

select * from daily
