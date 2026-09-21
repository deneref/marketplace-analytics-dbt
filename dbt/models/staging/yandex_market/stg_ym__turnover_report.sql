{{ config(materialized='view') }}

-- Staging rule: rename, cast. No joins to other sources, no aggregation across records.
-- Grain: report_date × sku × cluster_name (verified unique on 2026-09-06, 3 monthly reports). Flat CSV, one row
-- per SHOP_SKU × MACROREGION_NAME per requested report date.
-- The report date is NOT a column — it is the second-to-last path segment of _SOURCE_FILE
-- (goods_turnover/<download_date>/<report_date>/turnover.csv), so it is cut out of the path here.
-- Two marketplace-formatted strings: TURNOVER = days or 'Нет продаж', AMOUNT = RUB or '-' — both go through
-- try_to_decimal, the text is kept as has_sales / storage_amount NULL.
-- The marketplace's own turnover, taken as is: fct_inventory_turnover_monthly publishes it without recomputing
-- (an own turnover and a reconciliation against this report were planned and dropped on 2026-09-06).

with src as (

    select * from {{ source_or_seed('goods_turnover') }}

),

dated as (

    select
        *,
        try_to_date(split_part(_source_file, '/', -2), 'YYYY-MM-DD') as report_date
    from src

),

latest as (

    -- the same report date can be downloaded more than once: keep the latest load per sku × cluster × date
    select *
    from dated
    qualify row_number() over (
        partition by report_date, shop_sku, macroregion_name
        order by _loaded_at desc
    ) = 1

),

renamed as (

    select
        report_date,
        shop_sku::varchar                                        as sku,
        macroregion_name::varchar                                as cluster_name,
        {{ dbt_utils.generate_surrogate_key(['report_date', 'shop_sku', 'macroregion_name']) }}
                                                                 as turnover_report_key,

        -- product as the report sees it
        market_sku::varchar                                      as market_sku,
        offer_name::varchar                                      as offer_name,
        category::varchar                                        as market_category_name,
        length::number(10, 1)                                    as length_mm,
        width::number(10, 1)                                     as width_mm,
        height::number(10, 1)                                    as height_mm,
        volume::number(10, 3)                                    as volume_l,

        -- velocity and stock over the report period
        try_to_decimal(turnover, 12, 6)                          as turnover_days,
        (turnover <> 'Нет продаж')                               as has_sales,
        avg_sold_items::number(12, 6)                            as avg_daily_units_sold,
        avg_sold_volume::number(12, 6)                           as avg_daily_volume_sold_l,
        avg_sold_volume_on_stock::number(12, 6)                  as avg_daily_volume_on_stock_l,
        items_on_stock::integer                                  as units_on_stock,

        -- storage billing and advice
        try_to_decimal(amount, 18, 2)                            as storage_amount,
        market_recommendation::varchar                           as market_recommendation,

        _loaded_at::timestamp_ntz                                as _loaded_at,
        _source_file::varchar                                    as _source_file
    from latest

)

select * from renamed
