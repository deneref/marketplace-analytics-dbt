{#- Gamma-Poisson helpers for rate estimates on thin data (rpt_stock_sku).
    shrunk_rate: posterior mean of a Poisson rate with a gamma prior worth `a` events at mean `prior`:
    (n + a) / (t + a / prior). NULL, not an error, when the prior is 0 or NULL.
    gamma_quantile: Wilson–Hilferty approximation of a gamma(shape, rate) quantile; accurate for shape >= 1. -#}

{% macro shrunk_rate(n, t, a, prior) -%}
    (({{ n }}) + {{ a }}) / (({{ t }}) + {{ a }} / nullif({{ prior }}, 0))
{%- endmacro %}

{% macro gamma_quantile(shape, rate, z) -%}
    ({{ shape }}) * power(greatest(0, 1 - 1 / (9 * ({{ shape }})) + ({{ z }}) * sqrt(1 / (9 * ({{ shape }})))), 3) / ({{ rate }})
{%- endmacro %}
