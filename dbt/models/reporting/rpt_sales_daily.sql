-- The sales page of the dashboard: one wide row per day × sku × outcome × loss reason × what was kept instead, the
-- facts joined to their product attributes. Two kinds of rows share the columns:
--   * outcome = 'delivered' — fct_sales_daily as is: units received, revenue and margin recognised on the day the
--     buyer received the goods (event_date = delivered_date);
--   * outcome = 'unredeemed' / 'returned' — the units that came back and what they cost: lines of fct_order_lines with
--     refused or returned units, aggregated to the day the units were received back by the warehouse
--     (event_date = rejected_date / returned_date, falling back to the order's status change when the event carries no
--     date — about 7 % of events).
-- The union lives in reporting, not in the mart: fct_sales_daily stays a table of sales ("a sale is a delivered
-- unit"), and a dashboard page reads one source. With it the page's margin is the margin AFTER unredeemed and returned
-- parcels — SUM(contribution_margin) over all rows — while the margin of what was sold is the same sum filtered to
-- outcome = 'delivered'. Losses are recognised later than sales (a parcel sits unclaimed, then travels back), and the
-- lag is longer than it feels: from the day the order was cancelled to the day the warehouse booked the units back is
-- a median of 5 days but a mean of 8.6, a 90th percentile of 12 and a maximum of 84 (n = 764 refused lines,
-- 2026-09-14); for returns, a median of 9.5 and a maximum of 68. The last MONTH of any period undercounts losses.
-- A return is also restated backwards rather than booked forwards: it drops units_delivered on the original line, so
-- the sale leaves the day it was received rather than being reversed on the day it came back. Closed months move.
--
-- Every unit that came back is here, including the units of a line that kept some and lost others — the brand reads
-- refusals by sku and by product type, so the units of a sku must all be present or its rate is wrong. Money is a
-- different matter: fees are not scaled by delivery, so a line already counted as a sale pays its FULL fees there, and
-- its loss row carries units only with zero money (`money_belongs_here` below). One line in the whole history is in
-- that state as of 2026-09-14, but the rule is what keeps a share of losses honest when there are more.
-- The page shows a line that was sold or a line that lost units — and nothing else: lines cancelled before shipment
-- and lines still in flight appear in neither half (160 lines / 161 units as of 2026-09-14, carrying 4 ₽ of fees in
-- total, because the marketplace charges almost nothing for a parcel it never shipped). So units_delivered + units_lost
-- is the units of the lines this page shows, NOT the units the brand has ever ordered (2 369 against 2 530).
-- Revenue and cogs are 0 on every loss row, and that is a consequence, not an assumption: the fact recognises both
-- only when delivered_date is not null, and a line that HAS a delivered_date and still carries its money here has
-- units_delivered = 0 — so revenue (price × delivered/ordered) and cogs (delivered × unit cost) are both 0.
--
-- WHY the units came back is `loss_reason`, decided in int_order_cancellations and int_order_lines and passed through
-- fct_order_lines untouched — this view classifies nothing. It is NULL on delivered rows and on returned rows: a return
-- happens after receipt and the buyer's own stated reason for it lives in the returns API, which is not ingested.
-- Only one of the reasons is about the ITEM, and that is the whole point of carrying the reason at all. Of 817 refused
-- units (2026-09-14): refused_at_handover 510 — the parcel reached the counter and the buyer did not take it; and
-- not_collected 181 + cancelled_by_buyer 110 + delivery_failed 13 + not_paid 3 = 307 units where the sku was a
-- passenger in a parcel nobody opened. A rate built over ALL lost units of a sku measures parcels, not cards; filter to
-- outcome = 'unredeemed' AND loss_reason = 'refused_at_handover' before drawing conclusions about a product.
-- `units_lost_inferred` is the honest companion of the reason, and the honesty is needed: of those 510 refusals, 442
-- (87 %) rest on the storage-window inference — the parcel arrived, nobody asked to cancel, the order ended inside the
-- storage period — and only 68 units are evidence (55 where the order proves the parcel was opened, 13 the marketplace
-- itself called a refusal). Across all 817 lost units 475 carry an inferred reason. A cell of three refusals where all
-- three are inferred is not evidence about a product. A measure, not a dimension, so the caveat survives every cut
-- without adding colours to a legend.
-- `kept_instead` is the one thing this view does derive, because it needs dim_products, which the facts deliberately do
-- not carry: for a refusal in an order that kept something, what did the buyer keep instead of this item — the same
-- model in another size (the size grid failed), the same model and size in another colour, another unit of the very
-- same sku, or another item. WHETHER the order kept anything is decided upstream (is_order_partly_kept, the same flag
-- that makes the reason 'refused_at_handover'); only WHICH is decided here. Null everywhere else.
-- 55 lines carry a label as of 2026-09-14: other_item 22, other_colour 21, other_size 11, same_sku 1. No line on that
-- data matches two labels, so the priority in the CASE is stated, not exercised. Read each label for exactly what it
-- says, and no further:
--   * other_size and other_colour are the SAME behaviour — the buyer ordered two variants of one model and kept one.
--     Which label it gets is decided by the product type, not by the buyer: caps and scarves are sizeless (size = ONE),
--     so other_size is structurally impossible for them, and 19 of the 21 other_colour lines are caps. The labels are
--     therefore not comparable ACROSS product types.
--   * other_size is a size-bracketing signal, not a verdict on the grid: 11 lines over 20 months, and the direction
--     contradicts itself — 7 kept the larger size, 4 the smaller, and within one model (H-005) it goes both ways.
--     The direction is not carried here; the drill for it is fct_order_lines.
--   * same_sku is self-evidence: the line kept part of its OWN units, so it is guaranteed for every partially
--     delivered line (all 1 of them so far) and says nothing about another item.
--   * other_item is the remainder — "kept something, and it was not this model". It also absorbs the cases where the
--     comparison could not be made (a kept sku with no dim_products row or an unparsed code: none today).
--
-- At what level these numbers can be read, measured on the whole history (817 refused units, 44 skus): by product type
-- and model the CELLS hold (caps 321 units, long sleeves 229, hoodies 170); by sku × reason they do not — 122 such
-- cells, median 3 units, exactly one unit in 30 of them. Note what a big cell does and does not buy: n is large mostly
-- because the reasons that say nothing about the item dominate, so a large cell is a licence to compare, not a licence
-- to conclude — the filter above (refused_at_handover, inferred share next to it) is what makes it about the product.
-- kept_instead is thinner still: by model × label it is 24 cells with a median of ONE unit and a maximum of 16, so it
-- is a list to read, never a chart to rank, and the project's n ≥ 5 rule bites hardest exactly here.
--
-- dim_products is one row per sku, so the join cannot fan out. unique(sales_daily_key) is what proves it, and for the
-- delivered half it is the ONLY guard — assert_rpt_sales_daily_matches_fact.sql compares a duplicated row with the
-- single fact row and finds equal measures on both copies. The loss half is guarded twice over: a duplicate would
-- double the units in assert_rpt_sales_daily_losses_match_lines.sql and the fees in
-- assert_rpt_sales_daily_fees_counted_once.sql. Note that none of these tests has a scheduled run yet (CI is dbt parse
-- plus a build on demo seeds, the daily job selects staging), so they guard when dbt test is run by hand.
--
-- Why this layer exists at all. The Snowflake connector for Looker Studio does not push filters down for
-- DATE / TIME / TIMESTAMP columns, so the date control on a dashboard never narrows the query — the dataset has to be
-- small by itself. Its 1M-row / 50MB quota is counted per data source, and blends take at most five sources, aggregate
-- each one before joining and cannot be reused across reports. Add our own rule that facts carry keys only, and a
-- dashboard reading fct_sales_daily directly would be a chart of SKU codes. Hence one wide view per dashboard page,
-- joined here rather than in the BI tool.
--
-- What is deliberately NOT here:
--   * ratios (margin %, fee share, average price, unredeemed rate) — the numerator and the denominator are both columns
--     and BI divides the sums; a stored ratio returns garbage under any grouping. Each ratio has a catch and they are
--     written out once, in the yml, next to the column they divide: the unredeemed rate needs a FILTERED numerator
--     (see units_lost), the promotion share only holds on delivered rows (see fee_boost). Do not restate them here —
--     this comment and the yml have already drifted apart once;
--   * calendar attributes (week, month, weekday) — Looker Studio derives them from event_date;
--   * days without sales — the table is sparse and BI draws the zeros. Skus that never sold are absent by definition;
--   * dbt_updated_at — no widget needs it, and a third date column makes Looker Studio pick the wrong default date
--     range dimension;
--   * current_basic_price — the brand's prices are public on the marketplace, and the columns here must match
--     rpt_sales_daily_public one for one. A real price next to masked money recovers the multiplier by division;
--   * the fee mix broken out by type — that is the "order economics" page, and it needs fee_type unpivoted into rows.
--     fee_boost is the exception: promotion is the one cost the brand changes day to day — though it is dated here by
--     receipt, not by the day of the auction, so it answers "what did the units received today cost in promotion";
--   * market_category_name — one-to-one with product_type, which is already here (a singular test checks it);
--   * the raw substatus and the rule that decided the reason — an audit trail belongs to the facts, not to a page.
--
-- Column names are ASCII only: the connector rejects anything else in field names.
--
-- View, not table: the source is a 1.2k-row table and every dashboard query scans the whole set anyway.

{{ config(materialized='view') }}

with products as (

    select * from {{ ref('dim_products') }}

),

sales as (

    select
        delivered_date                                                      as event_date,
        sku,
        'delivered'                                                         as outcome,
        cast(null as varchar)                                               as loss_reason,
        cast(null as varchar)                                               as kept_instead,
        units_delivered,
        0                                                                   as units_lost,
        0                                                                   as units_lost_defect,
        0                                                                   as units_lost_inferred,
        sku_orders_count,
        lines_count,
        revenue,
        fee_total,
        fee_boost,
        cogs,
        cogs_estimated,
        contribution_margin
    from {{ ref('fct_sales_daily') }}

),

loss_lines as (

    -- every line that lost units: the reason it arrives with, the date each kind of loss is recognised on, and the
    -- product attributes the evidence needs
    select
        l.order_line_key,
        l.order_id,
        l.sku,
        l.loss_reason,
        l.loss_reason_is_inferred,
        l.is_order_partly_kept,                                         -- upstream's answer to "did this order keep anything"
        l.units_rejected,
        l.units_returned,
        l.units_rejected_defect,
        l.units_returned_defect,
        l.rejected_date,                                                -- each branch below dates itself; a single date
        l.returned_date,                                                -- here would stamp returned units with the refusal
        {{ moscow_date('l.status_updated_at') }}                        as status_date,   -- fallback: 62 of 898 loss events carry no date of their own
        -- Fees belong on the loss row unless the line is already counted as a sale. The condition is the exact
        -- complement of fct_sales_daily's filter, NOT `units_delivered = 0`: an in-flight line carries units_delivered
        -- as a FORECAST with no delivered_date, so it is in neither half and its fees would vanish from the page.
        not (l.delivered_date is not null and l.units_delivered > 0)     as money_belongs_here,
        l.fee_total,
        l.fee_boost,
        p.model_code,                                                   -- H-001: the model without size or colour
        p.size                                                          -- S / M / L / XL, or ONE for sizeless items
    from {{ ref('fct_order_lines') }} as l
    left join products as p
        on p.sku = l.sku
    where l.units_rejected + l.units_returned > 0
      and not coalesce(l.is_test_order, false)

),

kept_variants as (

    -- what the buyer DID keep, per order: the other half of the comparison. The filter is fct_sales_daily's definition
    -- of a kept unit — the date matters, not just the count, because an in-flight line carries units_delivered as a
    -- FORECAST and would otherwise count as kept.
    -- The products join is LEFT: a kept sku missing from dim_products, or one whose code did not parse, must still
    -- count as kept — it becomes 'other_item' evidence. An inner join dropped it and turned an order that kept
    -- something into an order that kept nothing.
    select distinct
        l.order_id,
        l.sku,
        p.model_code,
        p.size
    from {{ ref('fct_order_lines') }} as l
    left join products as p
        on p.sku = l.sku
    where l.delivered_date is not null
      and l.units_delivered > 0
      and not coalesce(l.is_test_order, false)

),

kept_evidence as (

    -- per lost line: what else did the buyer keep from the same order? The model comparison sits in the AGGREGATES, not
    -- in the join — joining on model_code kept only same-model evidence, which made 'other_item' unreachable and turned
    -- the 22 lines (of 55) whose order kept a different model into nulls.
    -- model_code is null for a sku whose code did not parse: it cannot be compared by model, so it counts as evidence
    -- of 'other_item' rather than as a match (assert_sku_codes_parse warns about such skus upstream).
    select
        ll.order_line_key,
        boolor_agg(k.model_code = ll.model_code
                   and k.size is distinct from ll.size)                 as kept_other_size,
        boolor_agg(k.model_code = ll.model_code
                   and k.size is not distinct from ll.size
                   and k.sku <> ll.sku)                                 as kept_other_colour,
        boolor_agg(k.sku = ll.sku)                                      as kept_same_sku
    from loss_lines as ll
    join kept_variants as k
        on k.order_id = ll.order_id
    group by 1

),

loss_rows as (

    -- one row per lost line × kind of loss. A line with both refused and returned units becomes two rows, because the
    -- outcome of a unit is not a property of the line: each row is dated by ITS OWN event, and the money goes with the
    -- refused row (the parcel came back unbought, which is the dominant event) so that nothing is counted twice.
    -- No line in the history has both as of 2026-09-14 — 815 lines lost units to a refusal, 81 to a return, none to
    -- both — so this split is a rule the data has not exercised yet, not a description of it.
    select
        coalesce(ll.rejected_date, ll.status_date)                       as event_date,
        ll.sku,
        'unredeemed'                                                    as outcome,
        ll.loss_reason,
        -- WHETHER the buyer kept something is not decided here — it is is_order_partly_kept from int_order_lines, the
        -- same flag that makes the reason 'refused_at_handover'. WHICH thing they kept is decided here, because that
        -- needs dim_products. The evidence here is a strict SUBSET of the upstream flag by construction (kept_variants
        -- also demands a delivered_date), so the first branch cannot fire on a line that has evidence; it fires only
        -- where the two definitions have come apart — an order whose kept units are still a FORECAST, which int does
        -- not exclude and this view does. There the label stays null instead of guessing, and
        -- assert_rpt_sales_daily_kept_instead_covered.sql turns that gap into a red test.
        case
            when not coalesce(ll.is_order_partly_kept, false)           then null
            when e.order_line_key is null                               then null
            when coalesce(e.kept_other_size, false)                     then 'other_size'
            when coalesce(e.kept_other_colour, false)                   then 'other_colour'
            when coalesce(e.kept_same_sku, false)                       then 'same_sku'
            -- exhaustive: a kept sku is either this sku, the same model in another size, the same model and size in
            -- another colour, or something else — so the fall-through IS 'other_item', never a silent null
            else                                                             'other_item'
        end                                                             as kept_instead,
        ll.units_rejected                                               as units_lost,
        ll.units_rejected_defect                                        as units_lost_defect,
        iff(coalesce(ll.loss_reason_is_inferred, false), ll.units_rejected, 0) as units_lost_inferred,
        ll.order_id,
        ll.order_line_key,
        iff(ll.money_belongs_here, ll.fee_total, 0)                     as fee_total,
        iff(ll.money_belongs_here, ll.fee_boost, 0)                     as fee_boost
    from loss_lines as ll
    left join kept_evidence as e
        on e.order_line_key = ll.order_line_key
    where ll.units_rejected > 0

    union all

    -- returned units: dated by the return, and no reason (the returns API is not ingested) and no evidence about what
    -- was kept instead — the buyer had the whole order in hand, so the comparison says nothing
    select
        coalesce(ll.returned_date, ll.status_date)                       as event_date,
        ll.sku,
        'returned'                                                      as outcome,
        cast(null as varchar)                                           as loss_reason,
        cast(null as varchar)                                           as kept_instead,
        ll.units_returned                                               as units_lost,
        ll.units_returned_defect                                        as units_lost_defect,
        0                                                               as units_lost_inferred,
        ll.order_id,
        ll.order_line_key,
        iff(ll.money_belongs_here and ll.units_rejected = 0, ll.fee_total, 0) as fee_total,
        iff(ll.money_belongs_here and ll.units_rejected = 0, ll.fee_boost, 0) as fee_boost
    from loss_lines as ll
    where ll.units_returned > 0

),

losses as (

    -- Fees are passed through from the lines, never recomputed. Revenue and cogs are literal zeros, and they are
    -- allowed to be: a line whose money lands here has units_delivered = 0 or no delivered_date, so both are 0 in the
    -- fact as well (see the header), and a line whose money does NOT land here books them in its delivered row.
    -- contribution_margin is the fees with the sign flipped.
    select
        event_date,
        sku,
        outcome,
        loss_reason,
        kept_instead,
        0                                                                   as units_delivered,
        sum(units_lost)                                                     as units_lost,
        sum(units_lost_defect)                                              as units_lost_defect,
        sum(units_lost_inferred)                                            as units_lost_inferred,
        count(distinct order_id)                                            as sku_orders_count,
        count(*)                                                            as lines_count,
        0                                                                   as revenue,
        sum(fee_total)                                                      as fee_total,
        sum(fee_boost)                                                      as fee_boost,
        0                                                                   as cogs,
        0                                                                   as cogs_estimated,
        -sum(fee_total)                                                     as contribution_margin
    from loss_rows
    group by 1, 2, 3, 4, 5

),

events as (

    -- both sides list their columns: `union all` matches by POSITION, every column here is a number or a string, and a
    -- column inserted into one branch only would line up silently against the wrong one
    select
        event_date, sku, outcome, loss_reason, kept_instead, units_delivered, units_lost, units_lost_defect,
        units_lost_inferred, sku_orders_count, lines_count, revenue, fee_total, fee_boost, cogs, cogs_estimated,
        contribution_margin
    from sales
    union all
    select
        event_date, sku, outcome, loss_reason, kept_instead, units_delivered, units_lost, units_lost_defect,
        units_lost_inferred, sku_orders_count, lines_count, revenue, fee_total, fee_boost, cogs, cogs_estimated,
        contribution_margin
    from losses

),

final as (

    select
        -- keys and grain
        {{ dbt_utils.generate_surrogate_key(['e.event_date', 'e.sku', 'e.outcome', 'e.loss_reason', 'e.kept_instead']) }}
                                                                            as sales_daily_key,
        e.event_date,                                                       -- delivered: day of receipt; losses: day the units came back
        e.sku,
        e.outcome,                                                          -- delivered | unredeemed | returned
        e.loss_reason,                                                      -- why the refused units came back; null on delivered and returned rows
        e.kept_instead,                                                     -- what the buyer kept instead of this item, where the order proves they kept something

        -- product attributes: the reason this layer exists
        p.product_name,
        p.product_type_code,
        p.product_type,                                                     -- the dashboard's main axis, and the level at which the reason mix is readable
        p.model_code,
        p.model_name,
        p.model_colour_code,                                                -- colourway: the level at which a restock is decided
        p.colour_name,
        p.size,
        p.size_order,                                                       -- without it Looker sorts L, M, S, XL
        p.collection,
        p.lifecycle_status,
        p.launch_date,

        -- days since the model launched: the axis for a drop cohort ("units sold by day N after launch"), which is
        -- readable at this volume where a time series is not — the brand sells a median of three units a day.
        -- Checked against the data: of 1 469 sold lines none precede their model's launch_date, so this is never
        -- negative today. It is null when the model has no launch_date in the product_models seed — the relationships
        -- test does NOT catch that, the seed row exists with an empty date.
        -- CAVEAT: launch_date in the seed is a proxy — the model's first ORDER date — while event_date is the day of
        -- receipt, so day 0 never occurs (observed range 1…577) and the offset is the delivery lag. For loss rows it is
        -- the days from launch to the day the parcel came back — informational only.
        datediff(day, p.launch_date, e.event_date)                          as days_since_launch,

        p.is_in_catalogue,                                                  -- filter: include withdrawn cards or not

        -- units
        e.units_delivered,                                                  -- 0 on loss rows
        e.units_lost,                                                       -- units that came back; 0 on delivered rows. The rate it belongs to has a filtered numerator — the formula lives in the yml, once
        e.units_lost_defect,                                                -- of those, booked unsellable by the warehouse: a lower bound, and their cost is written off nowhere yet
        e.units_lost_inferred,                                              -- of those, the units whose reason rests on the storage-window inference rather than a statement
        e.sku_orders_count,                                                 -- orders containing this sku in this row; NOT additive across skus
        e.lines_count,

        -- money, all RUB. Delivered rows: recognised on delivered_date and restated on returns. Loss rows: fees only,
        -- and only from lines that kept nothing — a line that kept part of its units carries its full fees in its
        -- delivered row (see the header).
        e.revenue,
        e.fee_total,
        e.fee_boost,                                                        -- promotion, inside fee_total — not added on top
        e.cogs,
        e.cogs_estimated,                                                   -- part of cogs resting on a planned cost; share = cogs_estimated / cogs in BI
        e.contribution_margin                                               -- revenue − fee_total − cogs; on loss rows = −fee_total

    from events as e
    left join products as p
        on p.sku = e.sku
    -- left, not inner: the fact already carries a relationships test to dim_products at severity error, and a view
    -- feeding a dashboard should not silently drop a day of sales the moment a new sku outruns the catalogue snapshot.
    -- A missing row surfaces as null attributes, which the not_null tests below report.

)

select * from final
