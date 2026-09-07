-- ==============================================================================
-- MODEL: mart_station_od_flows_hourly.sql
-- WARSTWA: 03_Gold (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/gold/mart_station_od_flows_hourly.parquet (~29 MB)
--
-- CEL MODELU:
-- 1. Analiza potoków ruchu między stacjami w czasie (Origin-Destination Matrix / Flows).
-- 2. Agregacja przejazdów do poziomu trasy (stacja A -> stacja B) w poszczególnych godzinach.
-- 3. Wzbogacenie o koordynaty GPS i nazwy obu krańców trasy z dim_station_distances.
-- 4. Bezpośrednie zasilenie map przepływów (Flow Maps / Spider Maps / ArcGIS) w Power BI.
-- ==============================================================================

{{ config(
    location='data/gold/mart_station_od_flows_hourly.parquet',
    options={"overwrite_or_ignore": true}
) }}

WITH aggregated_trips AS (
    -- Krok 1: Zagregowanie podróży rowerowych do poziomu trasy w danej godzinie
    SELECT
        start_station_uid,
        end_station_uid,
        date_trunc('hour', start_ts) AS hour_ts,
        CAST(date_trunc('hour', start_ts) AS DATE) AS dt,
        EXTRACT('hour' FROM start_ts)::INT AS hour_of_day,
        EXTRACT('isodow' FROM start_ts)::INT AS day_of_week, -- 1=Poniedziałek, 7=Niedziela
        (EXTRACT('isodow' FROM start_ts) IN (6, 7)) AS is_weekend,
        COUNT(*) AS trips_count,
        ROUND(AVG(duration_minutes), 1) AS avg_duration_minutes,
        ROUND(AVG(speed_kmh), 2) AS avg_speed_kmh
    FROM {{ ref('fct_bike_trips') }}
    GROUP BY 1, 2, 3, 4, 5, 6, 7
)

SELECT
    -- Atrybuty czasu i kalendarza
    t.hour_ts,
    t.dt,
    t.hour_of_day,
    t.day_of_week,
    t.is_weekend,

    -- Stacja początkowa (Origin) - nazwa i położenie geograficzne
    t.start_station_uid,
    d.start_station_name,
    d.start_latitude,
    d.start_longitude,

    -- Stacja docelowa (Destination) - nazwa i położenie geograficzne
    t.end_station_uid,
    d.end_station_name,
    d.end_latitude,
    d.end_longitude,

    -- Dystans geodezyjny i miary ruchu na trasie
    d.distance_km,
    t.trips_count,
    t.avg_duration_minutes,
    t.avg_speed_kmh

FROM aggregated_trips t
LEFT JOIN {{ ref('dim_station_distances') }} d
       ON t.start_station_uid = d.start_station_uid
      AND t.end_station_uid   = d.end_station_uid
ORDER BY t.hour_ts, t.trips_count DESC
