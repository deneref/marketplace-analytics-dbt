-- The marketplace's goods-turnover report as a periodic snapshot fact.
-- Grain: report_month × sku × cluster_name — the report's own grain, so turnover_report_key comes from staging.
-- Taken as is: the marketplace's turnover is the benchmark, we do not compute our own (our stock snapshots start
-- 2026-09, the report covers the history). turnover_days is non-additive and is stored next to its numerator
-- (units_on_stock) and denominator (avg_daily_units_sold); how the marketplace derives it is checked in analyses/.
-- Reports are requested for the last day of a month only (tested in staging), so report_month is the one date.
-- Product attributes printed in the report (name, category, volume) belong to dim_products.
-- Table, not incremental: a published report never changes, and it is ~60 rows a month.

{{ config(materialized='table') }}

with report as (

    select *
    from {{ ref('stg_ym__turnover_report') }}

),

final as (

    select
        -- keys
        turnover_report_key,
        date_trunc('month', report_date)    as report_month,
        sku,
        cluster_name,

        -- attributes
        has_sales,
        market_recommendation,

        -- units: end-of-period stock and daily averages over the period
        units_on_stock,
        avg_daily_units_sold,
        avg_daily_volume_sold_l,
        avg_daily_volume_on_stock_l,

        -- metric: marketplace's turnover in days, NULL when 'Нет продаж' — do not sum
        turnover_days,

        -- money: paid storage, RUB; '-' in the report means not billed → 0 and the flag
        coalesce(storage_amount, 0)         as storage_amount,
        storage_amount is not null          as is_storage_billed,

        current_timestamp()                 as dbt_updated_at

    from report

)

select * from final
