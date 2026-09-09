-- Cost versions of one SKU must tile the timeline without gaps or overlaps:
-- every version except the last closes exactly the day before the next one opens, and only the last may be open-ended.
-- A gap = delivered lines with no cost; an overlap = a line matching two costs (both caught by assert_delivered_lines_have_unit_cost,
-- but here at the source, before the join).
{{ config(severity='error') }}

with versions as (

    select
        sku,
        valid_from,
        valid_to,
        lead(valid_from) over (partition by sku order by valid_from) as next_valid_from
    from {{ ref('stg_finance__unit_costs') }}

)

select
    sku,
    valid_from,
    valid_to,
    next_valid_from,
    case
        when valid_to is null                       then 'open-ended version followed by another'
        when valid_to < next_valid_from - 1         then 'gap before next version'
        when valid_to >= next_valid_from            then 'overlaps next version'
    end                                             as problem
from versions
where next_valid_from is not null
  and (valid_to is null or valid_to <> next_valid_from - 1)
