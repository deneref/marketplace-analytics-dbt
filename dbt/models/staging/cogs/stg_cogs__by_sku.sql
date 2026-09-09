{{ config(materialized='view') }}

-- Unit cost (COGS) per SKU × validity period, from the cost workbooks (data/raw/cogs/<date>/by_sku.csv).
-- Grain: sku × valid_from. One row per cost version; versions of one SKU do not overlap (tests/assert_cogs_versions_are_continuous.sql).
--
-- Staging rule: rename, cast. No joins, no derived business logic. Strict casts on purpose: the file is ours and
-- checked before load, so a bad value should fail the build, not turn into NULL.
--
-- Latest FILE wins as a whole, not latest row per key: a corrected workbook may drop a version (two batches merged
-- into one), and "latest per sku × valid_from" would keep the dropped version alive. The loader stamps every row
-- of one file with the same _loaded_at, so the file loaded last is the current truth.
--
-- UNIT_COST = materials + manufacturing + print + label + packaging + shipping + other, where shipping is the INBOUND
-- logistics of the batch (factory → warehouse), NOT the marketplace delivery fee (that is fee_delivery in int_order_lines).
-- Development, photo shoots, marketing and payroll are deliberately outside COGS (see 06_пет-проект/07_cogs_разбор.md).

with src as (

    select * from {{ source_or_seed('cogs_by_sku', 'cogs') }}

),

latest_file as (

    select *
    from src
    qualify _source_file = first_value(_source_file) over (order by _loaded_at desc)

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['sku', 'valid_from']) }}   as sku_cost_key,
        sku::varchar                                            as sku,
        valid_from::date                                        as valid_from,
        valid_to::date                                          as valid_to,           -- null = open-ended (current version)

        -- money, RUB per unit
        unit_cost::number(18, 4)                                as unit_cost,
        cost_materials::number(18, 4)                           as cost_materials,
        cost_manufacturing::number(18, 4)                       as cost_manufacturing,
        cost_print::number(18, 4)                               as cost_print,
        cost_label::number(18, 4)                               as cost_label,
        cost_packaging::number(18, 4)                           as cost_packaging,
        cost_shipping::number(18, 4)                            as cost_shipping,      -- inbound logistics of the batch
        cost_other::number(18, 4)                               as cost_other,
        currency::varchar                                       as currency,           -- RUB so far

        -- where the number comes from
        cost_basis::varchar                                     as cost_basis,         -- batch_actual | supply_allocated | plan_2024
        is_estimate::boolean                                    as is_estimate,        -- true = planned, not actual
        has_cost_breakdown::boolean                             as has_cost_breakdown, -- false = only the total is known (2024 supplies)

        -- batch context (documentation, not used downstream)
        batch_label::varchar                                    as batch_label,
        batch_period::varchar                                   as batch_period,
        batch_units::number(18, 0)                              as batch_units,
        product_name::varchar                                   as product_name,       -- as written in the workbook; canonical names come from dim_products
        sku_in_catalogue::boolean                               as sku_in_catalogue,   -- at file build time; goes stale — the relationships test is the live check
        source_file::varchar                                    as workbook_file,
        source_sheet::varchar                                   as workbook_sheet,
        note::varchar                                           as note,

        _loaded_at::timestamp_ntz                               as _loaded_at,
        _source_file::varchar                                   as _source_file
    from latest_file

)

select * from renamed
