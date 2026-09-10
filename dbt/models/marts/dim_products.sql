-- The product as a DIMENSION: one row per seller SKU with everything the dashboard filters and groups by.
-- Grain: sku (offerId = shopSku) — the only identifier present in all four sources (orders, stocks, realization,
-- turnover report); the marketplace does not allow changing it after the card is created. market_sku is a
-- secondary lookup only: it can be absent (card not yet bound) and re-bound.
--
--   * Type 1: the current card. Names change over time and nobody needs "the name at the time of sale";
--     the price at the time of sale lives in fct_order_lines; card history is snap_offers;
--   * the row of a SKU comes from the LAST snapshot in which the SKU was seen, not from the latest export:
--     a deleted card keeps its category, colour and size (is_in_catalogue = false) instead of vanishing from
--     a year of sales; a partial export is caught by tests/assert_catalogue_not_shrunk.sql, not swallowed;
--   * size, colour, model and colourway are parsed from the seller's own SKU code (see sku_parts) — the
--     marketplace has no such fields; a code that does not fit the convention gets NULLs, not wrong values;
--   * editorial facts (model name, drop, launch, lifecycle) come from the hand-maintained seeds;
--   * lifecycle dates only, no sales sums: sums are measures of the fact, dates are descriptive attributes.
-- Table: a few dozen rows, rebuilt on every run.

{#- The closed list of sizes, in one place: the parser's regex, the sort key and the accepted_values test in the
    yml all derive from it. Add XS / XXL here (and in the yml) when the brand adds them. -#}
{% set sizes = ['S', 'M', 'L', 'XL'] %}

{{ config(materialized='table') }}

with catalogue as (

    -- last snapshot in which each SKU was seen; staging already keeps one load per sku × day.
    -- The window runs before qualify, so "is this the latest export" is known in the same pass.
    select
        sku,
        market_sku,
        snapshot_date,
        snapshot_date = max(snapshot_date) over ()  as is_in_catalogue,
        product_name,
        market_category_name,
        card_status,
        is_archived,
        basic_price,
        price_before_discount,
        length_cm,
        width_cm,
        height_cm,
        weight_kg
    from {{ ref('stg_ym__offers') }}
    qualify row_number() over (
        partition by sku
        order by snapshot_date desc, _loaded_at desc
    ) = 1

),

warehouse_skus as (

    -- the label the marketplace warehouse prints for the SKU (K4 for CAP-Bur-006); equals sku for most cards.
    -- Only the realization report carries it; the latest report (and load) wins should it ever change.
    -- tests/assert_warehouse_labels_resolve.sql checks that every label of the report lands on a row here.
    select
        sku,
        warehouse_sku
    from {{ ref('stg_ym__realization_lines') }}
    where warehouse_sku is not null
    qualify row_number() over (
        partition by sku
        order by report_month desc, _loaded_at desc
    ) = 1

),

-- Convention (after upper()): <type>-<size>-<colour>-<model number> for sized items (H-L-B-001),
--                             <type>-<colour>-<model number>        for one-size items (CAP-BUR-006, SC-GR-001).
-- Which shape applies is decided by product_types.has_sizes, NOT by counting segments —
-- a code with a missing segment must fail the parse, not silently become a one-size item.
sku_parts as (

    select
        sku,
        upper(sku)                                      as sku_upper,
        split_part(upper(sku), '-', 1)                  as product_type_code,
        split_part(upper(sku), '-', -1)                 as model_number_raw
    from catalogue

),

parsed as (

    select
        p.sku,
        p.product_type_code,
        t.product_type,

        -- size and colour sit in different positions depending on the type
        case
            when t.has_sizes then split_part(p.sku_upper, '-', 2)
            else 'ONE'
        end                                             as size,
        case
            when t.has_sizes then split_part(p.sku_upper, '-', 3)
            else split_part(p.sku_upper, '-', 2)
        end                                             as colour_code,

        -- model number normalised to three digits: CAP-BG-6 and CAP-BG-006 are the same model
        lpad(p.model_number_raw, 3, '0')                as model_number,

        -- the whole code must match the shape its type demands
        case
            when t.product_type_code is null then false                     -- unknown type
            when t.has_sizes
                then regexp_like(p.sku_upper, '^[A-Z]+-({{ sizes | join('|') }})-[A-Z]+-[0-9]{1,3}$')
            else regexp_like(p.sku_upper, '^[A-Z]+-[A-Z]+-[0-9]{1,3}$')
        end                                             as is_sku_parsed

    from sku_parts as p
    left join {{ ref('product_types') }} as t
        on t.product_type_code = p.product_type_code

),

sku_attributes as (

    -- attributes are NULL when the code does not fit the convention: a NULL is visible, a wrong value is not.
    -- Nulling happens here, before the seed joins, so an unparsed code cannot pick up a colour or a model.
    select
        sku,
        product_type_code,
        product_type,
        is_sku_parsed,
        iff(is_sku_parsed, size, null)                                          as size,
        case iff(is_sku_parsed, size, null)
            when 'ONE' then 0
            {% for s in sizes -%}
            when '{{ s }}' then {{ loop.index }}
            {% endfor -%}
        end                                                                     as size_order,
        iff(is_sku_parsed, colour_code, null)                                   as colour_code,
        iff(is_sku_parsed, product_type_code || '-' || model_number, null)      as model_code,          -- H-001
        iff(is_sku_parsed, product_type_code || '-' || colour_code || '-' || model_number, null)
                                                                                as model_colour_code    -- H-B-001
    from parsed

),

order_stats as (

    -- lifecycle dates of the SKU as seen in orders (history starts 2025-01: for older models first_ordered_date
    -- is the start of the data, not the first demand). first_ordered_date counts every order, cancelled
    -- included: the first time somebody wanted the item. last_delivered_date counts only units actually
    -- received, on the day of receipt — the same rule as delivered_date in fct_order_lines (macro moscow_date).
    -- RETURNED orders are left out: their status timestamp is the return, not the receipt. Test orders never count.
    select
        sku,
        min(ordered_date)::date                                                 as first_ordered_date,
        max(iff(order_status in ('DELIVERED', 'PARTIALLY_DELIVERED') and units_delivered > 0,
                {{ moscow_date('status_updated_at') }},
                null))                                                          as last_delivered_date
    from {{ ref('int_order_lines') }}
    where not is_test_order
    group by sku

),

final as (

    select
        -- keys
        c.sku,
        c.market_sku,
        coalesce(w.warehouse_sku, c.sku)                                        as warehouse_sku,

        -- name and classification
        c.product_name,
        c.market_category_name,
        a.product_type_code,
        a.product_type,
        a.model_code,
        coalesce(pm.model_name, a.model_code)                                   as model_name,
        a.model_colour_code,
        a.colour_code,
        cc.colour_name,
        a.size,
        a.size_order,
        a.is_sku_parsed,

        -- lifecycle: editorial (seed) and observed (orders)
        pm.collection,
        pm.lifecycle_status,
        pm.launch_date,
        pm.discontinued_date,
        os.first_ordered_date,
        os.last_delivered_date,

        -- current price list, not for revenue: the price at the time of sale is in fct_order_lines
        c.basic_price                                                           as current_basic_price,
        coalesce(c.price_before_discount, c.basic_price)                        as current_price_before_discount,

        -- package
        (c.length_cm * c.width_cm * c.height_cm / 1000)::number(18, 3)          as volume_l,
        c.weight_kg,

        -- card status
        c.card_status,
        c.is_archived,
        c.is_in_catalogue,
        c.snapshot_date                                                         as catalogue_snapshot_date,

        current_timestamp()                                                     as dbt_updated_at

    from catalogue as c
    left join sku_attributes as a
        on a.sku = c.sku
    left join warehouse_skus as w
        on w.sku = c.sku
    left join order_stats as os
        on os.sku = c.sku
    left join {{ ref('colour_codes') }} as cc
        on cc.colour_code = a.colour_code
    left join {{ ref('product_models') }} as pm
        on pm.model_code = a.model_code

)

select * from final
