-- ==============================================================================
-- MODEL: mart_trips_enriched.sql
-- WARSTWA: 03_Gold (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/gold/mart_trips_enriched.parquet (~60 MB)
--
-- CEL MODELU:
-- 1. Analityka finansowa i taryfowa: wyliczenie rzeczywistych opłat za przejazd wg cennika Nextbike.
-- 2. Implementacja logiki anty-resetowej: jeśli ten sam rower zostanie ponownie wypożyczony
--    w czasie <= 15 minut od zakończenia poprzedniego kursu, czas trwania się sumuje.
-- 3. Symulacja biznesowa: wyliczenie przychodów w scenariuszu skrócenia darmowego czasu z 20 do 15 minut.
-- 4. Detekcja uszkodzonych rowerów (flaga is_defect: zwrot w czasie <= 3 min i dystansie <= 300 m).
-- 5. Przygotowanie przedziałów kategorycznych (binning) pod osie wykresów Power BI.
-- ==============================================================================

{{ config(
    location='data/gold/mart_trips_enriched.parquet',
    options={"overwrite_or_ignore": true}
) }}

WITH trips_with_lag AS (
    -- Krok 1: Podglądamy czas zakończenia i czas trwania poprzedniego kursu tego samego roweru
    SELECT 
        *,
        LAG(end_ts)           OVER (PARTITION BY bike_uid ORDER BY start_ts) AS prev_end_ts,
        LAG(duration_minutes) OVER (PARTITION BY bike_uid ORDER BY start_ts) AS prev_duration
    FROM {{ ref('fct_bike_trips') }}
),

trips_billed AS (
    -- Krok 2: Zastosowanie reguły anty-resetowej (Anti-Reset Pricing Rule).
    -- Zapobiega ona "darmowej jeździe w kółko" poprzez ciągłe przepinanie roweru co 19 minut.
    SELECT 
        *,
        CASE 
            WHEN prev_end_ts IS NOT NULL 
             AND date_diff('minute', prev_end_ts, start_ts) <= 15 
            THEN duration_minutes + COALESCE(prev_duration, 0)
            ELSE duration_minutes
        END AS billing_duration_minutes
    FROM trips_with_lag
)

SELECT 
    bike_uid,
    start_station_uid,
    end_station_uid,
    start_ts,
    end_ts,
    dt,
    EXTRACT('hour' FROM start_ts)::INT AS hour_of_day,
    EXTRACT('isodow' FROM start_ts)::INT AS day_of_week, -- 1=Poniedziałek, 7=Niedziela
    (EXTRACT('isodow' FROM start_ts) IN (6, 7)) AS is_weekend,
    duration_minutes,
    distance_km,
    speed_kmh,

    -- Flaga podejrzenia usterki technicznej roweru:
    -- Użytkownik wypożycza rower, po czym w ciągu 1-3 minut oddaje go na tę samą (lub sąsiednią) stację.
    (duration_minutes <= 3 AND distance_km <= 0.3) AS is_defect,

    -- Oficjalny cennik Veturilo Warszawa (Taryfa standardowa: pierwsze 20 min darmowe):
    -- 0-20 min: 0 PLN
    -- 21-60 min: 1 PLN
    -- druga godzina: +3 PLN (łącznie 4 PLN)
    -- trzecia godzina: +5 PLN (łącznie 9 PLN)
    -- każda kolejna godzina: +7 PLN
    -- powyżej 12h: opłata specjalna 200 PLN
    CASE
        WHEN billing_duration_minutes > 720 THEN 200.0
        WHEN billing_duration_minutes <= 20 THEN 0.0
        WHEN billing_duration_minutes <= 60 THEN 1.0
        WHEN billing_duration_minutes <= 120 THEN 4.0
        WHEN billing_duration_minutes <= 180 THEN 9.0
        ELSE 9.0 + (CEIL((billing_duration_minutes - 180) / 60.0) * 7.0)
    END AS estimated_fee_pln,

    -- Symulacja dla działu przychodów: co gdyby darmowe było tylko pierwsze 15 minut?
    CASE
        WHEN billing_duration_minutes > 720 THEN 200.0
        WHEN billing_duration_minutes <= 15 THEN 0.0
        WHEN billing_duration_minutes <= 60 THEN 1.0
        WHEN billing_duration_minutes <= 120 THEN 4.0
        WHEN billing_duration_minutes <= 180 THEN 9.0
        ELSE 9.0 + (CEIL((billing_duration_minutes - 180) / 60.0) * 7.0)
    END AS simulated_fee_15m_pln,

    -- Koszyki analityczne pod osie wykresów w Power BI:
    CASE
        WHEN duration_minutes <= 10 THEN '0-10 min'
        WHEN duration_minutes <= 20 THEN '10-20 min'
        WHEN duration_minutes <= 30 THEN '20-30 min'
        WHEN duration_minutes <= 60 THEN '30-60 min'
        ELSE '> 60 min'
    END AS duration_bracket,

    (FLOOR(distance_km / 0.5) * 0.5) AS distance_bin_start,
    FLOOR(speed_kmh)::INT            AS speed_bin_start

FROM trips_billed