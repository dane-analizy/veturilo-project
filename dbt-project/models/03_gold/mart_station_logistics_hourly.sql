-- ==============================================================================
-- MODEL: mart_station_logistics_hourly.sql
-- WARSTWA: 03_Gold (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/gold/mart_station_logistics_hourly.parquet (~3.5 MB)
--
-- CEL MODELU:
-- 1. Analityka logistyki stacji i zarządzania flotą (Rebalancing stacji).
-- 2. Wyliczenie godzinowego bilansu netto rowerów: ile rowerów ubyło (wypożyczenia),
--    a ile przybyło (zwroty) na każdą stację w poszczególnych godzinach.
-- 3. Automatyczna klasyfikacja operacyjna roli stacji dla ekip technicznych:
--    - 'Źródło (Wypływ)': stacje z deficytem rowerów (wymagają dowiezienia sprzętu),
--    - 'Zlew (Przypływ)': stacje przepełnione (wymagają odbioru nadmiaru rowerów),
--    - 'Zrównoważona': stacje o zbalansowanym ruchu.
-- ==============================================================================

{{ config(
    location='data/gold/mart_station_logistics_hourly.parquet',
    options={"overwrite_or_ignore": true}
) }}

WITH state_lag AS (
    -- Krok 1: Dla każdej stacji podglądamy liczbę dostępnych rowerów z poprzedniej minuty
    SELECT 
        station_uid,
        ts,
        free_bikes::INT AS free_bikes,
        LAG(free_bikes::INT) OVER (PARTITION BY station_uid ORDER BY ts) AS prev_free_bikes,
        LAG(ts) OVER (PARTITION BY station_uid ORDER BY ts)         AS prev_ts
    FROM {{ ref('fct_station_snapshots') }}
),

deltas AS (
    -- Krok 2: Wyłapujemy tylko te minuty, w których faktycznie nastąpiła zmiana liczby rowerów.
    -- bike_delta < 0 oznacza wypożyczenie (rower ubył ze stacji),
    -- bike_delta > 0 oznacza zwrot (rower przybył na stację).
    SELECT 
        station_uid,
        ts,
        free_bikes - prev_free_bikes AS bike_delta
    FROM state_lag
    WHERE prev_free_bikes IS NOT NULL
      AND (free_bikes - prev_free_bikes) <> 0 
      -- Zabezpieczenie przed przerwami w zbieraniu danych (ignorujemy skoki po downtime > 10 min)
      AND (ts - prev_ts) <= INTERVAL '10 minutes'
)

SELECT 
    station_uid,
    date_trunc('hour', ts) AS hour_ts,
    CAST(date_trunc('hour', ts) AS DATE) AS dt,
    EXTRACT('hour' FROM ts)::INT AS hour_of_day,
    EXTRACT('isodow' FROM ts)::INT AS day_of_week, -- 1=Poniedziałek, 7=Niedziela
    (EXTRACT('isodow' FROM ts) IN (6, 7)) AS is_weekend,
    
    -- Metryki wolumenu przepływów w ciągu godziny:
    SUM(CASE WHEN bike_delta < 0 THEN ABS(bike_delta) ELSE 0 END) AS outgoing_trips,
    SUM(CASE WHEN bike_delta > 0 THEN bike_delta ELSE 0 END)       AS incoming_trips,
    SUM(bike_delta)                                                AS net_balance,

    -- Reguła biznesowa: klasyfikacja stacji dla ekip relokacyjnych
    CASE
        WHEN SUM(bike_delta) < -2 THEN 'Źródło (Wypływ)'
        WHEN SUM(bike_delta) > 2  THEN 'Zlew (Przypływ)'
        ELSE 'Zrównoważona'
    END AS station_role

FROM deltas
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY dt, hour_ts, station_uid