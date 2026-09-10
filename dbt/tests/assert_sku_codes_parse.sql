{{ config(severity='warn') }}

-- Catalogue SKUs whose code does not fit the seller's convention (<type>-<size>-<colour>-<number>, or without the
-- size segment for one-size types). Such a SKU has no size, colour, model or colourway in dim_products, so it
-- drops out of every hierarchy cut in the dashboard. A warning, not an error: one typo on the marketplace must
-- not stop the whole reporting layer. Fix the code on the marketplace, or add the new type / colour to the seeds.

select
    sku,
    product_type_code,
    product_name
from {{ ref('dim_products') }}
where is_in_catalogue
  and not is_sku_parsed
