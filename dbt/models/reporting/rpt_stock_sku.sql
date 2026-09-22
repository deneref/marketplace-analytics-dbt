-- The restock page: ONE ROW PER SKU as of the latest stock report — every number a restock decision needs, with the
-- evidence behind it, and a number for EVERY sku (a NULL cannot be ranked; honesty goes into the label).
--
-- Velocity = units ORDERED per day in stock, on evidence days (in stock AND demand known). One estimator for every
-- sku — gamma-Poisson shrinkage (macros/gamma_poisson.sql): the sku's own evidence days, weighted by how many
-- IN-STOCK days back they are (a stockout pauses the clock), shrunk to a prior = type rate × size index. A sku with
-- plenty of sales gets its own rate, a new one gets the prior, the rest a blend; the posterior gives the interval.
-- velocity_restock (the batch's arrival window) and kept_share are shrunk the same way.
--
-- v4.2: the base of velocity_restock is velocity_now, not velocity_recent. The in-stock clock puts the "now" of a
-- sku at zero since March in winter or spring, while the season index assumes the base is now; that counted the
-- season twice. velocity_now = the sku's strength against its type's month curve on its own evidence days × the
-- curve now. Method, backtest and the choice of the vars: the model description in _rpt_stock__models.yml.
--
-- Grain: sku (~51 rows). TABLE: Looker widgets would otherwise recompute the aggregates over the dense grid.

{{ config(materialized='table') }}

{% set lead = var('restock_lead_days') %}
{% set horizon = var('restock_horizon_days') %}
{% set half_life = var('velocity_half_life_days') %}
{% set a = var('velocity_prior_units') %}
{% set a_season = var('season_prior_units') %}
{% set k_index = var('index_prior_units') %}
{% set k_kept = var('kept_prior_units') %}
{% set min_units = var('velocity_min_units') %}
{% set clamp = var('season_index_clamp') %}
{% set min_cover = var('season_min_coverage') %}

with days as (

    -- today's row included: a sku whose first report is the latest one still gets a row (with zero evidence)
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

    select distinct
        latest_snapshot_date,
        latest_demand_date,
        latest_demand_date - 180                                    as recent_from,
        dateadd(year, -1, latest_snapshot_date + {{ lead }})        as season_from,       -- (from, to]: a batch started today
        dateadd(year, -1, latest_snapshot_date + {{ lead }} + {{ horizon }})
                                                                    as season_to,         -- sells in this window, a year back
        dateadd(year, -1, latest_demand_date)                       as recent_ly_to       -- "now", a year back
    from days
    where is_latest_day

),

calendar_weights as (

    -- every calendar day up to the end of the order feed (fct_stock_sku_daily is dense over the calendar), weighted
    -- by calendar age from it: the days "now" is averaged over
    select distinct
        d.date_day,
        date_trunc('month', d.date_day)::date                       as month_start,
        power(0.5, datediff(day, d.date_day, w.latest_demand_date) / {{ half_life }}::float)
                                                                    as w_now
    from days as d
    cross join windows as w
    where d.date_day <= w.latest_demand_date

),

evidence_days as (

    select
        d.sku,
        p.product_type_code,
        date_trunc('month', d.date_day)::date                       as month_start,
        d.units_ordered,
        d.units_kept,
        d.units_ordered - coalesce(d.units_in_flight, 0)            as units_resolved,    -- outcome known: kept, unredeemed, returned or cancelled
        -- weight by IN-STOCK days back from the sku's latest one, not calendar days
        power(0.5, (row_number() over (partition by d.sku order by d.date_day desc) - 1) / {{ half_life }}::float)
                                                                    as w_now,
        -- the type's rate "now, a year back" (season index denominator) — calendar weights around that date
        iff(d.date_day <= w.recent_ly_to,
            power(0.5, datediff(day, d.date_day, w.recent_ly_to) / {{ half_life }}::float), 0)
                                                                    as w_ly,
        d.date_day > w.recent_from                                  as is_r180,
        d.date_day > w.season_from and d.date_day <= w.season_to    as is_season
    from days as d
    cross join windows as w
    left join products as p
        on p.sku = d.sku
    where d.is_history
      and d.is_in_stock
      and d.is_demand_known

),

type_curve as (

    -- the type's rate per sku-day in each calendar month: all evidence days, unweighted, pooled over the skus in
    -- stock; a month is shrunk to the type's lifetime rate with index_prior_units. Used to move a sku's rate between
    -- dates (velocity_now), never as a season index: the index stays the v4 one
    select
        m.product_type_code,
        m.month_start,
        (m.units + {{ k_index }}) / (m.sku_days + {{ k_index }} / nullif(l.type_level, 0))
                                                                    as curve_rate
    from (
        select
            product_type_code,
            month_start,
            sum(units_ordered)::float                               as units,
            count(*)                                                as sku_days
        from evidence_days
        group by product_type_code, month_start
    ) as m
    inner join (
        select
            product_type_code,
            sum(units_ordered)::float / nullif(count(*), 0)         as type_level
        from evidence_days
        group by product_type_code
    ) as l
        on l.product_type_code = m.product_type_code

),

type_now as (

    -- the curve decay-weighted around the end of the order feed, over the days the type has a month for. Coverage =
    -- the share of the calendar's weight on those days: low when the whole type has been at zero for months
    select
        v.product_type_code,
        sum(c.w_now * v.curve_rate) / nullif(sum(c.w_now), 0)       as type_curve_now,
        sum(c.w_now) / nullif(any_value(t.w_total), 0)              as type_curve_now_coverage
    from calendar_weights as c
    inner join type_curve as v
        on v.month_start = c.month_start
    cross join (select sum(w_now) as w_total from calendar_weights) as t
    group by v.product_type_code

),

sku_history as (

    select
        d.sku,
        min(d.first_stocked_date)                                   as first_stocked_date,
        max(iff(d.is_history and d.is_in_stock, d.date_day, null))  as last_in_stock_date,
        count_if(d.is_history and d.is_stockout_day and d.date_day > w.latest_snapshot_date - 90)
                                                                    as stockout_days_90
    from days as d
    cross join windows as w
    group by d.sku

),

sku_evidence as (

    select
        h.sku,
        h.first_stocked_date,
        h.last_in_stock_date,
        h.stockout_days_90,
        count(e.sku)                                                as life_in_stock_days,
        coalesce(sum(e.units_ordered), 0)                           as life_units_ordered,
        coalesce(sum(e.units_kept), 0)                              as life_units_kept,
        count_if(e.is_r180)                                         as r180_in_stock_days,
        coalesce(sum(iff(e.is_r180, e.units_ordered, 0)), 0)        as r180_units_ordered,
        count_if(e.is_season)                                       as season_in_stock_days,
        coalesce(sum(iff(e.is_season, e.units_ordered, 0)), 0)      as season_units_ordered,
        coalesce(sum(e.w_now), 0)                                   as t_eff,
        coalesce(sum(e.w_now * e.units_ordered), 0)                 as n_eff,
        coalesce(sum(e.w_now * e.units_kept), 0)                    as kept_eff,
        coalesce(sum(e.w_now * e.units_resolved), 0)                as resolved_eff,
        coalesce(sum(e.w_ly), 0)                                    as t_eff_ly,
        coalesce(sum(e.w_ly * e.units_ordered), 0)                  as n_eff_ly,
        -- units the type curve expects on the same days, with the same weights
        coalesce(sum(e.w_now * v.curve_rate), 0)                    as e_eff
    from sku_history as h
    left join evidence_days as e
        on e.sku = h.sku
    left join type_curve as v
        on v.product_type_code = e.product_type_code
       and v.month_start = e.month_start
    group by h.sku, h.first_stocked_date, h.last_in_stock_date, h.stockout_days_90

),

brand as (

    -- NULL (→ NULL velocities → the not_null tests fail loudly) only if the brand has no orders at all
    select
        sum(n_eff) / nullif(sum(t_eff), 0)                          as brand_velocity,
        sum(n_eff_ly) / nullif(sum(t_eff_ly), 0)                    as brand_velocity_ly,
        sum(kept_eff) / nullif(sum(resolved_eff), 0)                as brand_kept_share
    from sku_evidence

),

type_rates as (

    select
        p.product_type_code,
        {{ shrunk_rate('sum(e.n_eff)', 'sum(e.t_eff)', a, 'any_value(b.brand_velocity)') }}
                                                                    as type_velocity,
        (sum(e.kept_eff) + {{ k_kept }} * any_value(b.brand_kept_share)) / (sum(e.resolved_eff) + {{ k_kept }})
                                                                    as type_kept_share,
        -- season index: the type's orders in the arrival window a year back ÷ what its rate "now, a year back"
        -- predicted for those days, shrunk to 1. NULL (→ 1, 'no_history') when the type barely existed a year back
        iff(sum(e.t_eff_ly) >= 30,
            (sum(e.season_units_ordered) + {{ k_index }})
          / (sum(e.season_in_stock_days)
               * {{ shrunk_rate('sum(e.n_eff_ly)', 'sum(e.t_eff_ly)', a, 'any_value(b.brand_velocity_ly)') }}
             + {{ k_index }}),
            null)                                                   as type_season_index_raw
    from sku_evidence as e
    inner join products as p
        on p.sku = e.sku
    cross join brand as b
    group by p.product_type_code

),

size_pairs as (

    -- each non-M size against the M of the SAME colourway (Mantel–Haenszel rate ratio): a size effect free of
    -- which models happen to come in that size
    select
        p.size,
        e.n_eff * m.t_eff / nullif(e.t_eff + m.t_eff, 0)            as mh_num,
        m.n_eff * e.t_eff / nullif(e.t_eff + m.t_eff, 0)            as mh_den
    from sku_evidence as e
    inner join products as p
        on p.sku = e.sku
    inner join products as pm
        on pm.model_colour_code = p.model_colour_code
       and pm.size = 'M'
    inner join sku_evidence as m
        on m.sku = pm.sku
    where p.size not in ('M', 'ONE')

),

size_ratios as (

    select
        size,
        (coalesce(sum(mh_num), 0) + {{ k_index }}) / (coalesce(sum(mh_den), 0) + {{ k_index }})
                                                                    as size_ratio_to_m
    from size_pairs
    group by size

),

sku_size as (

    select
        p.sku,
        p.product_type_code,
        iff(p.size is null or p.size in ('M', 'ONE'), 1, coalesce(r.size_ratio_to_m, 1))
                                                                    as size_ratio_to_m
    from products as p
    left join size_ratios as r
        on r.size = p.size

),

type_size_norm as (

    -- rescale the ratios so a type's exposure-weighted average is 1: type_velocity stays the type's level
    select
        s.product_type_code,
        sum(e.t_eff * s.size_ratio_to_m) / nullif(sum(e.t_eff), 0)  as size_norm
    from sku_evidence as e
    inner join sku_size as s
        on s.sku = e.sku
    group by s.product_type_code

),

today as (

    select *
    from days
    where is_latest_day

),

enriched as (

    select
        e.*,
        t.latest_snapshot_date,
        t.latest_demand_date,
        t.units_available_sod,
        t.units_fit_sod,
        t.units_freeze_sod,
        t.units_unsellable_sod,
        t.units_fit_at_returns_sod,
        coalesce(t.is_in_stock, false)                              as is_in_stock,
        coalesce(t.is_stockout_day, false)                          as is_stockout_now,
        coalesce(tr.type_velocity, b.brand_velocity)                as type_velocity,
        coalesce(tr.type_kept_share, b.brand_kept_share)            as type_kept_share,
        coalesce(ss.size_ratio_to_m, 1)                             as size_ratio_to_m,
        coalesce(ss.size_ratio_to_m, 1) / coalesce(n.size_norm, 1)  as size_index,
        -- the type's curve now; its lifetime rate when it has none. A season index only when "now" is known: a
        -- type at zero for months has an old "now", and the index ("now" a year back → arrival) would count the
        -- season again
        coalesce(tn.type_curve_now, coalesce(tr.type_velocity, b.brand_velocity))
                                                                    as type_curve_now,
        coalesce(tn.type_curve_now_coverage, 0)                     as type_curve_now_coverage,
        iff(coalesce(tn.type_curve_now_coverage, 0) >= {{ min_cover }}, tr.type_season_index_raw, null)
                                                                    as type_season_index_raw,
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
    from sku_evidence as e
    inner join today as t
        on t.sku = e.sku
    cross join brand as b
    left join products as p
        on p.sku = e.sku
    left join type_rates as tr
        on tr.product_type_code = p.product_type_code
    left join type_now as tn
        on tn.product_type_code = p.product_type_code
    left join sku_size as ss
        on ss.sku = e.sku
    left join type_size_norm as n
        on n.product_type_code = p.product_type_code

),

rated as (

    select
        *,
        least({{ clamp[1] }}, greatest({{ clamp[0] }}, coalesce(type_season_index_raw, 1)))
                                                                    as type_season_index,
        iff(type_season_index_raw is null, 'no_history',
            iff(type_season_index_raw between {{ clamp[0] }} and {{ clamp[1] }}, 'type_last_year', 'clamped'))
                                                                    as season_index_basis,
        e_eff / nullif(t_eff, 0)                                    as type_curve_on_evidence,
        -- the sku against its type on the SAME days (1 = the type's rate), shrunk to its size index. NULL when it
        -- has sales but no curve under them (a sku missing from dim_products); velocity_now then falls back to
        -- velocity_recent
        iff(n_eff > 0 and e_eff = 0, null, {{ shrunk_rate('n_eff', 'e_eff', a, 'size_index') }})
                                                                    as velocity_strength,
        type_velocity * size_index                                  as velocity_prior,
        {{ shrunk_rate('n_eff', 't_eff', a, 'type_velocity * size_index') }}
                                                                    as velocity_recent,
        {{ a }} + n_eff                                             as post_shape,
        {{ a }} / nullif(type_velocity * size_index, 0) + t_eff     as post_rate,
        -- of RESOLVED units only: the latest orders are still in flight, and with recency weights they would drag it down
        (kept_eff + {{ k_kept }} * type_kept_share) / (resolved_eff + {{ k_kept }})
                                                                    as kept_share
    from enriched

),

brought_to_now as (

    -- what the sku would sell per in-stock day now, whenever its own days were
    select
        *,
        coalesce(velocity_strength * type_curve_now, velocity_recent)
                                                                    as velocity_now
    from rated

),

restock as (

    select
        *,
        t_eff / post_rate                                           as velocity_recent_own_share,
        {{ gamma_quantile('post_shape', 'post_rate', -1.96) }}      as velocity_recent_lo,
        {{ gamma_quantile('post_shape', 'post_rate', 1.96) }}       as velocity_recent_hi,
        velocity_now * type_season_index                            as velocity_restock_prior,
        {{ shrunk_rate('season_units_ordered', 'season_in_stock_days', a_season, 'velocity_now * type_season_index') }}
                                                                    as velocity_restock,
        season_in_stock_days
            / (season_in_stock_days + {{ a_season }} / nullif(velocity_now * type_season_index, 0))
                                                                    as velocity_restock_own_share
    from brought_to_now

),

final as (

    select
        sku,
        latest_snapshot_date,
        latest_demand_date,
        first_stocked_date,
        last_in_stock_date,

        -- stock this morning (network without returns warehouses)
        units_available_sod,
        units_fit_sod,
        units_freeze_sod,
        units_unsellable_sod,
        units_fit_at_returns_sod,
        is_in_stock,
        is_stockout_now,
        iff(is_stockout_now,
            datediff(day, coalesce(last_in_stock_date, first_stocked_date - 1), latest_snapshot_date + 1), null)
                                                                    as stockout_run_days,
        stockout_days_90,

        -- raw evidence, for the reader
        life_in_stock_days,
        life_units_ordered,
        life_units_kept,
        r180_in_stock_days,
        r180_units_ordered,
        season_in_stock_days,
        season_units_ordered,
        life_units_ordered   / nullif(life_in_stock_days, 0)        as velocity_lifetime,
        r180_units_ordered   / nullif(r180_in_stock_days, 0)        as velocity_recent_180,
        season_units_ordered / nullif(season_in_stock_days, 0)      as velocity_season_ly,

        -- velocity now
        n_eff                                                       as velocity_evidence_units,
        t_eff                                                       as velocity_evidence_days,
        type_velocity,
        size_ratio_to_m,
        size_index,
        velocity_prior,
        velocity_recent_own_share,
        case
            when n_eff >= {{ min_units }} then 'own'
            when n_eff >= 3               then 'blended'
            else                               'prior'
        end                                                         as velocity_recent_basis,
        velocity_recent,
        velocity_recent_lo,
        velocity_recent_hi,

        -- velocity when the batch lands: the sku brought to now on its type's curve, × the season index
        type_curve_on_evidence,
        velocity_strength,
        type_curve_now,
        type_curve_now_coverage,
        velocity_now,
        type_season_index_raw,
        type_season_index,
        season_index_basis,
        velocity_restock_prior,
        velocity_restock_own_share,
        case
            when season_units_ordered >= {{ min_units }} then 'own_season'
            when season_units_ordered >= 3               then 'blended'
            else                                              'recent_x_season'
        end                                                         as velocity_restock_basis,
        velocity_restock,

        kept_share,
        units_available_sod / velocity_recent                       as cover_days,
        stockout_days_90 * velocity_recent                          as lost_units_90,        -- upper estimate: size substitution not deducted
        {{ horizon }} * velocity_restock                            as units_ordered_horizon,
        {{ horizon }} * velocity_restock * kept_share               as units_kept_horizon,   -- batch size before today's stock is deducted
        {{ lead }}                                                  as restock_lead_days,
        {{ horizon }}                                               as restock_horizon_days,
        -- live, delivered at least once, sells ≥ 1 unit during the lead time even at the LOWER bound (a prior alone
        -- does not make a candidate), and at zero now or runs out before a batch started today lands. Never NULL
        coalesce(lifecycle_status, 'core') not in ('discontinued', 'limited')
            and first_stocked_date is not null
            and coalesce(velocity_recent_lo * {{ lead }} >= 1, false)
            and coalesce(units_available_sod = 0 or units_available_sod / velocity_recent < {{ lead }}, false)
                                                                    as is_restock_candidate,

        product_name,
        product_type_code,
        product_type,
        model_code,
        model_name,
        model_colour_code,
        colour_name,
        size,
        size_order,
        collection,
        lifecycle_status,
        launch_date
    from restock

)

select * from final
