-- ==============================================================================
-- MODEL: fct_bike_trips.sql
-- WARSTWA: 02_Silver (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/silver/fct_bike_trips.parquet (~27 MB)
--
-- CEL MODELU:
-- 1. Kluczowa tabela faktów: wykrywanie rzeczywistych podróży rowerowych.
-- 2. Algorytm: Jeśli ten sam rower w kolejnych minutach zmienia stację (A != B),
--    oznacza to, że pomiędzy tymi zdarzeniami odbyła się podróż.
-- 3. Używa funkcji analitycznej LEAD() po oknie rowerowym (PARTITION BY bike_uid ORDER BY ts).
-- 4. Dołącza odległość geodezyjną z wymiaru dim_station_distances (1 szybki JOIN zamiast 2x ST_Distance).
-- 5. Czyści artefakty: odrzuca podróże < 1 min, > 12h oraz teleportacje serwisowe na lawetach (> 45 km/h).
-- ==============================================================================

{{ config(
    location='data/silver/fct_bike_trips.parquet',
    options={
        "overwrite_or_ignore": true
    }
) }}

WITH station_changes AS (
    -- Krok 1: Dla każdego roweru podglądamy stację i czas kolejnego zdarzenia w szeregu czasowym.
    -- Okno analityczne: partycjonujemy po rowerze, sortujemy chronologicznie.
    SELECT
        bike_uid,
        station_uid AS start_station_uid,
        ts          AS start_ts,
        LEAD(station_uid) OVER (PARTITION BY bike_uid ORDER BY ts) AS next_station_uid,
        LEAD(ts)          OVER (PARTITION BY bike_uid ORDER BY ts) AS next_ts
    FROM {{ ref('fct_bike_snapshots') }}
),

trips_raw AS (
    -- Krok 2: Wyłuskanie rzeczywistych zmian stacji (odrzucenie 98% wierszy bezruchu na stacji).
    -- next_station_uid IS NOT NULL odrzuca ostatni pomiar w serii obserwacji.
    SELECT
        bike_uid,
        start_station_uid,
        next_station_uid AS end_station_uid,
        start_ts,
        next_ts          AS end_ts,
        -- Przypisanie daty kalendarzowej podróży do momentu jej zakończenia:
        CAST(next_ts AS DATE) AS dt,
        date_diff('minute', start_ts, next_ts) AS duration_minutes
    FROM station_changes
    WHERE next_station_uid IS NOT NULL
      AND start_station_uid != next_station_uid
),

trips_with_distance AS (
    -- Krok 3: Wzbogacenie o dystans geograficzny z pre-kalkulowanej macierzy odległości.
    SELECT
        t.bike_uid,
        t.start_station_uid,
        t.end_station_uid,
        t.start_ts,
        t.end_ts,
        t.dt,
        t.duration_minutes,
        d.distance_km
    FROM trips_raw t
    LEFT JOIN {{ ref('dim_station_distances') }} d
           ON t.start_station_uid = d.start_station_uid
          AND t.end_station_uid   = d.end_station_uid
    -- Filtr czasu trwania:
    -- < 1 min: artefakt danych (rower pojawił się i zniknął w tej samej minucie)
    -- > 720 min (12h): awaria API, porzucenie roweru poza stacją lub błąd systemowy
    WHERE t.duration_minutes BETWEEN 1 AND 720
)

SELECT
    bike_uid,
    start_station_uid,
    end_station_uid,
    start_ts,
    end_ts,
    dt,
    duration_minutes,
    ROUND(distance_km, 3) AS distance_km,

    -- Obliczenie średniej prędkości przejazdu: dystans_km / (czas_min / 60.0)
    ROUND(
        distance_km / (duration_minutes / 60.0),
        2
    ) AS speed_kmh

FROM trips_with_distance
-- Filtr anomalii fizycznych:
-- Prędkość > 45 km/h to transport roweru busem serwisowym/lawetą, a nie jazda miejska.
WHERE (
        distance_km / (duration_minutes / 60.0)
) <= 45.0
ORDER BY dt, start_ts, end_ts