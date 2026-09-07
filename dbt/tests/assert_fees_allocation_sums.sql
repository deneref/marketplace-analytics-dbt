-- Allocation must neither lose nor create money:
-- fees allocated to the lines of an order sum to the fees of that order in the source, to the kopeck.
{{ config(severity='error') }}

with allocated as (

    select order_id, sum(fee_total) as fees
    from {{ ref('int_order_lines') }}
    group by 1

),

per_order as (

    select order_id, sum(fee_amount) as fees
    from {{ ref('stg_ym__order_fees') }}
    group by 1

)

select
    coalesce(a.order_id, p.order_id) as order_id,
    a.fees                           as allocated,
    p.fees                           as reported
from allocated as a
full outer join per_order as p
    on p.order_id = a.order_id
where coalesce(a.fees, 0) <> coalesce(p.fees, 0)
