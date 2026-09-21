-- The restock page: ONE ROW PER SKU, as of the latest stock report. Every number a restock decision needs, with
-- the evidence behind it (units and days) next to it — and a number for EVERY sku, because the page exists to rank
-- what to sew and a NULL cannot be ranked (decision of 2026-09-17: honesty goes into the label, not into a NULL).
--
-- Velocity = units ORDERED / days in stock, on days where BOTH the stock report and the order feed exist
-- (is_in_stock and is_demand_known). Days in stock and nothing finer: at the brand's demand of 0.1–0.3 orders a
-- day a single unit on the shelf censors at most λ − (1 − e^−λ) ≈ 10 % of the orders (Poisson), and the old
-- "depth" gate (2+ units) threw away 1 487 sku-days of evidence and left 7 skus of 51 with a number.
-- Two rates, because two questions:
--   * velocity_recent — how it sells NOW: last 180 calendar days, or lifetime under var('velocity_min_units')
--     units, or lifetime on thin evidence ('weak'), or the product type's rate for a sku never on sale
--     ('type_avg'). Used for cover_days, lost_units_90 and the candidate rule — the questions about the next
--     weeks, which are the same season as the last ones;
--   * velocity_restock — how it will sell WHEN THE BATCH LANDS: a batch started today sells in
--     [latest report + lead, + lead + horizon]. The sku's own rate in that window one year back when it has
--     velocity_min_units there ('season_own'; hoodies sell 0.2–0.3/day in Nov–Mar and 0.02–0.05 in summer, caps
--     the reverse); otherwise velocity_recent × the product type's season index (the type's rate in that window
--     a year back ÷ its rate in the last-180-days window a year back, clamped to [0.5, 1.5] because with one
--     year of history the index carries the brand's growth too; 'season_by_type'); otherwise velocity_recent
--     as is ('no_season'). Used for units_ordered_horizon / units_kept_horizon — the size of the batch.
-- velocity_recent_ci is the 95 % Poisson half-width (1.96·√units / days): at 10–30 units it is about ±35–60 %, so
-- the page shows it and never ranks two skus by a difference inside it.
--
-- Grain: sku. ~51 rows. TABLE, not view: every Looker widget would otherwise recompute three windows over the
-- dense grid, and two widgets could see two states of the fact. Rebuilt with fct_stock_sku_daily in seconds.

{{ config(materialized='table') }}

{% set lead = var('restock_lead_days') %}
{% set horizon = var('restock_horizon_days') %}
{% set min_units = var('velocity_min_units') %}

with days as (

    -- every row, today's included: a sku whose FIRST report is the latest one has only today's row, and it must
    -- still get a row here (with zero evidence). is_history keeps today's unfinished row out of every window
    select
        *,
        date_day <= latest_snapshot_date                            as is_history
    from {{ ref('fct_stock_sku_daily') }}

),

products as (

    select *
    from {{ ref('dim_products') }}

),

windows as (

    -- the four windows, as dates, once
    select
        latest_snapshot_date,
        latest_demand_date,
        latest_demand_date - 180                                    as recent_from,
        dateadd(year, -1, latest_snapshot_date + {{ lead }})        as season_from,       -- (from, to]
        dateadd(year, -1, latest_snapshot_date + {{ lead }} + {{ horizon }})
                                                                    as season_to,
        dateadd(year, -1, latest_demand_date - 180)                 as recent_ly_from,
        dateadd(year, -1, latest_demand_date)                       as recent_ly_to
    from days
    where is_latest_day
    limit 1

),

evidence as (

    -- days in stock with known demand, and the units ordered on them, per window (history rows only)
    select
        d.sku,
        min(d.first_stocked_date)                                   as first_stocked_date,
        max(iff(d.is_history and d.is_in_stock, d.date_day, null))  as last_in_stock_date,

        count_if(d.is_history and d.is_in_stock and d.is_demand_known)
                                                                    as life_in_stock_days,
        sum(iff(d.is_history and d.is_in_stock and d.is_demand_known, d.units_ordered, 0))
                                                                    as life_units_ordered,
        sum(iff(d.is_history and d.is_in_stock and d.is_demand_known, d.units_kept, 0))
                                                                    as life_units_kept,

        count_if(d.is_history and d.is_in_stock and d.is_demand_known and d.date_day > w.recent_from)
                                                                    as r180_in_stock_days,
        sum(iff(d.is_history and d.is_in_stock and d.is_demand_known and d.date_day > w.recent_from, d.units_ordered, 0))
                                                                    as r180_units_ordered,

        count_if(d.is_history and d.is_in_stock and d.is_demand_known and d.date_day > w.season_from and d.date_day <= w.season_to)
                                                                    as season_in_stock_days,
        sum(iff(d.is_history and d.is_in_stock and d.is_demand_known and d.date_day > w.season_from and d.date_day <= w.season_to, d.units_ordered, 0))
                                                                    as season_units_ordered,

        count_if(d.is_history and d.is_in_stock and d.is_demand_known and d.date_day > w.recent_ly_from and d.date_day <= w.recent_ly_to)
                                                                    as r180ly_in_stock_days,
        sum(iff(d.is_history and d.is_in_stock and d.is_demand_known and d.date_day > w.recent_ly_from and d.date_day <= w.recent_ly_to, d.units_ordered, 0))
                                                                    as r180ly_units_ordered,

        count_if(d.is_history and d.is_stockout_day and d.date_day > w.latest_snapshot_date - 90)
                                                                    as stockout_days_90     -- report days at zero in the last 90 calendar days
    from days as d
    cross join windows as w
    group by d.sku

),

type_rates as (

    -- the product type as the fallback for a sku without its own evidence: lifetime rate per sku-day, kept share,
    -- and the season index. NULL index (→ 'no_season') when either window of the type has < 30 units
    select
        p.product_type_code,
        sum(e.life_units_ordered) / nullif(sum(e.life_in_stock_days), 0)
                                                                    as type_velocity,
        sum(e.life_units_kept) / nullif(sum(e.life_units_ordered), 0)
                                                                    as type_kept_share,
        iff(sum(e.season_units_ordered) >= 30,
            sum(e.season_units_ordered) / nullif(sum(e.season_in_stock_days), 0), null)
                                                                    as type_velocity_season_ly,
        iff(sum(e.season_units_ordered) >= 30 and sum(e.r180ly_units_ordered) >= 30,
            least(1.5, greatest(0.5,
                (sum(e.season_units_ordered) / nullif(sum(e.season_in_stock_days), 0))
              / nullif(sum(e.r180ly_units_ordered) / nullif(sum(e.r180ly_in_stock_days), 0), 0))), null)
                                                                    as type_season_index
    from evidence as e
    inner join products as p
        on p.sku = e.sku
    group by p.product_type_code

),

today as (

    select *
    from days
    where is_latest_day

),

rated as (

    select
        e.sku,
        t.latest_snapshot_date,
        t.latest_demand_date,
        e.first_stocked_date,
        e.last_in_stock_date,

        -- stock this morning (network without returns warehouses)
        t.units_available_sod,
        t.units_fit_sod,
        t.units_freeze_sod,
        t.units_unsellable_sod,
        t.units_fit_at_returns_sod,
        coalesce(t.is_in_stock, false)                              as is_in_stock,
        coalesce(t.is_stockout_day, false)                          as is_stockout_now,
        iff(coalesce(t.is_stockout_day, false),
            datediff(day, coalesce(e.last_in_stock_date, e.first_stocked_date - 1), t.latest_snapshot_date + 1), null)
                                                                    as stockout_run_days,    -- mornings at zero so far, today's included; NULL when in stock
        e.stockout_days_90,

        -- evidence, all windows
        e.life_in_stock_days,
        e.life_units_ordered,
        e.life_units_kept,
        e.r180_in_stock_days,
        e.r180_units_ordered,
        e.season_in_stock_days,
        e.season_units_ordered,
        e.life_units_ordered   / nullif(e.life_in_stock_days, 0)    as velocity_lifetime,
        e.r180_units_ordered   / nullif(e.r180_in_stock_days, 0)    as velocity_recent_180,
        e.season_units_ordered / nullif(e.season_in_stock_days, 0)  as velocity_season_ly,

        -- velocity_recent: how it sells now
        case
            when e.r180_units_ordered >= {{ min_units }}                        then 'recent_180'
            when e.life_units_ordered >= {{ min_units }}                        then 'lifetime'
            when e.life_in_stock_days >= 14 or e.life_units_ordered > 0         then 'weak'
            else                                                                     'type_avg'
        end                                                         as velocity_recent_basis,
        case
            when e.r180_units_ordered >= {{ min_units }}                        then e.r180_units_ordered / e.r180_in_stock_days
            when e.life_units_ordered >= {{ min_units }}                        then e.life_units_ordered / e.life_in_stock_days
            when e.life_in_stock_days >= 14 or e.life_units_ordered > 0         then e.life_units_ordered / e.life_in_stock_days
            else                                                                     tr.type_velocity
        end                                                         as velocity_recent,
        iff(e.r180_units_ordered >= {{ min_units }}, e.r180_units_ordered, e.life_units_ordered)
                                                                    as velocity_recent_n_units,
        iff(e.r180_units_ordered >= {{ min_units }}, e.r180_in_stock_days, e.life_in_stock_days)
                                                                    as velocity_recent_n_days,

        -- velocity_restock: how it sells when the batch lands
        tr.type_season_index,
        tr.type_velocity_season_ly,
        case
            when e.season_units_ordered >= {{ min_units }}                      then 'season_own'
            when tr.type_season_index is not null                               then 'season_by_type'
            else                                                                     'no_season'
        end                                                         as velocity_restock_basis,

        -- kept share: of ordered units, received and kept (unredeemed and returned parcels are not sales)
        iff(e.life_units_ordered >= {{ min_units }},
            e.life_units_kept / e.life_units_ordered, tr.type_kept_share)
                                                                    as kept_share,

        p.product_name,
        p.product_type_code,
        p.product_type,
        p.model_code,
        p.model_name,
        p.model_colour_code,
        p.colour_name,
        p.size,
        p.size_order,
        p.collection,
        p.lifecycle_status,
        p.launch_date
    from evidence as e
    inner join today as t
        on t.sku = e.sku
    left join products as p
        on p.sku = e.sku
    left join type_rates as tr
        on tr.product_type_code = p.product_type_code

),

final as (

    select
        r.*,
        1.96 * sqrt(r.velocity_recent_n_units) / nullif(r.velocity_recent_n_days, 0)
                                                                    as velocity_recent_ci,   -- 95 % half-width, Poisson
        case r.velocity_restock_basis
            when 'season_own'     then r.velocity_season_ly
            when 'season_by_type' then r.velocity_recent * r.type_season_index
            else                       r.velocity_recent
        end                                                         as velocity_restock,
        iff(r.velocity_recent > 0, r.units_available_sod / r.velocity_recent, null)
                                                                    as cover_days,           -- mornings of stock left at velocity_recent; NULL at zero velocity
        r.stockout_days_90 * r.velocity_recent                      as lost_units_90,        -- upper estimate: size substitution not deducted
        {{ horizon }} * case r.velocity_restock_basis
            when 'season_own'     then r.velocity_season_ly
            when 'season_by_type' then r.velocity_recent * r.type_season_index
            else                       r.velocity_recent end        as units_ordered_horizon, -- orders in the batch's first {{ horizon }} days
        {{ horizon }} * r.kept_share * case r.velocity_restock_basis
            when 'season_own'     then r.velocity_season_ly
            when 'season_by_type' then r.velocity_recent * r.type_season_index
            else                       r.velocity_recent end        as units_kept_horizon,   -- of them, kept: the batch size before today's stock is deducted
        {{ lead }}                                                  as restock_lead_days,
        {{ horizon }}                                               as restock_horizon_days,
        -- a live model that has been delivered at least once, would sell at least one unit during the lead time,
        -- and is at zero now or runs out before a batch started today lands. FALSE, never NULL
        coalesce(r.lifecycle_status, 'core') not in ('discontinued', 'limited')
            and r.first_stocked_date is not null
            and coalesce(r.velocity_recent * {{ lead }} >= 1, false)
            and coalesce(r.units_available_sod = 0
                         or r.units_available_sod / nullif(r.velocity_recent, 0) < {{ lead }}, false)
                                                                    as is_restock_candidate
    from rated as r

)

select * from final
