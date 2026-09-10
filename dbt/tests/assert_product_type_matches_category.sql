{{ config(severity='warn') }}

-- Our taxonomy (product_type from the SKU code) and the marketplace's (market_category_name) describe the same
-- thing from two sides, so each product type must map to exactly one marketplace category and vice versa.
-- A mismatch is either a typo in the SKU code (a hoodie coded as a t-shirt) or a card bound to the wrong
-- marketplace category — both worth a look, neither worth a red build. Free cross-check, no hand-made data.
-- Cards not yet bound to a marketplace card have no category and are left out.

with pairs as (

    select
        product_type_code,
        market_category_name,
        count(*) as n_sku
    from {{ ref('dim_products') }}
    where is_in_catalogue
      and market_category_name is not null
    group by product_type_code, market_category_name

),

ambiguous as (

    select *
    from pairs
    qualify count(*) over (partition by product_type_code) > 1
         or count(*) over (partition by market_category_name) > 1

)

select *
from ambiguous
