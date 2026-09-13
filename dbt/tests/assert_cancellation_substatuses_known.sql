-- The blind spot of int_order_cancellations, made visible.
-- A substatus the tree does not name does NOT become 'unknown' — the tree has no such fallback. It falls through the
-- named rules into the storage-window rules and comes out as 'refused_at_handover' or 'not_collected', which is the
-- headline number of the whole loss analysis. So a value the marketplace has never sent before can move money between
-- categories without failing a single test: accepted_values on the staging column only warns that the value is new, and
-- nothing says it landed in an inference.
-- Today exactly two substatuses reach those rules — USER_CHANGED_MIND (356 cancellations) and FULL_NOT_RANSOM (86) —
-- and both are deliberate: neither states WHY the parcel came back, so the window is the only instrument left.
-- This test fails when a third one appears there. Warn, not error: a new marketplace value is news, not a broken
-- pipeline, and the daily job builds staging. The fix is to classify it in the model's Jinja sets (or to add it here
-- with a reason why the window may judge it).

{{ config(severity='warn') }}

with window_ruled as (

    select
        order_substatus,
        reason_rule,
        count(*)                                    as orders,
        min(cancelled_at)::date                     as first_seen,
        max(cancelled_at)::date                     as last_seen
    from {{ ref('int_order_cancellations') }}
    where reason_rule in ('within_storage_window', 'after_storage_window', 'arrival_is_handover')
      and order_substatus not in ('USER_CHANGED_MIND', 'FULL_NOT_RANSOM')
    group by 1, 2

)

select * from window_ruled
