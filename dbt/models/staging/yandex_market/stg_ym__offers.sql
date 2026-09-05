{{ config(materialized='view') }}

-- Staging rule: rename, cast, unnest. No joins to other sources, no aggregation across records.
-- Grain: offer (sku) × snapshot_date. RAW has one row per offer per daily catalogue export, with OFFER and MAPPING
-- as JSON text: OFFER is the seller's card (name, vendor, price, dimensions), MAPPING is the marketplace's view of
-- it (marketSku, category). Long/derived fields (description, pictures, campaigns) are deliberately left out.

with src as (

    select * from {{ source_or_seed('offer_mappings') }}

),

latest as (

    -- the same day can be exported more than once: keep the latest load per offer × day
    select *
    from src
    qualify row_number() over (
        partition by snapshot_date, parse_json(offer):offerId
        order by _loaded_at desc
    ) = 1

),

parsed as (

    select
        snapshot_date,
        parse_json(offer)   as offer,
        parse_json(mapping) as mapping,
        _loaded_at,
        _source_file
    from latest

),

renamed as (

    select
        offer:offerId::varchar                                                  as sku,
        snapshot_date::date                                                     as snapshot_date,
        {{ dbt_utils.generate_surrogate_key(['offer:offerId', 'snapshot_date']) }} as offer_snapshot_key,

        -- seller's card
        offer:name::varchar                                                     as product_name,
        offer:vendor::varchar                                                   as vendor,
        offer:vendorCode::varchar                                               as vendor_code,
        offer:category::varchar                                                 as seller_category,
        offer:type::varchar                                                     as product_type,
        offer:groupId::varchar                                                  as group_id,
        offer:cardStatus::varchar                                               as card_status,
        coalesce(offer:archived::boolean, false)                                as is_archived,
        offer:barcodes[0]::varchar                                              as barcode,

        -- price
        offer:basicPrice:value::number(18, 2)                                   as basic_price,
        offer:basicPrice:discountBase::number(18, 2)                            as price_before_discount,
        offer:basicPrice:currencyId::varchar                                    as price_currency,
        try_to_timestamp_tz(offer:basicPrice:updatedAt::varchar)                as price_updated_at,

        -- dimensions (marketplace units: cm and kg)
        offer:weightDimensions:length::number(10, 2)                            as length_cm,
        offer:weightDimensions:width::number(10, 2)                             as width_cm,
        offer:weightDimensions:height::number(10, 2)                            as height_cm,
        offer:weightDimensions:weight::number(10, 3)                            as weight_kg,

        -- marketplace's mapping of the card
        mapping:marketSku::varchar                                              as market_sku,
        mapping:marketSkuName::varchar                                          as market_sku_name,
        mapping:marketModelId::varchar                                          as market_model_id,
        mapping:marketModelName::varchar                                        as market_model_name,
        mapping:marketCategoryId::varchar                                       as market_category_id,
        mapping:marketCategoryName::varchar                                     as market_category_name,

        _loaded_at::timestamp_ntz                                               as _loaded_at,
        _source_file::varchar                                                   as _source_file
    from parsed

)

select * from renamed
