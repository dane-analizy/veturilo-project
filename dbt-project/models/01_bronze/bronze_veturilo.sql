-- ==============================================================================
-- MODEL: bronze_veturilo.sql
-- WARSTWA: 01_Bronze (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do partycjonowanych plików Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/bronze/veturilo/dt=YYYY-MM-DD/data_0.parquet
--
-- CEL MODELU:
-- 1. Odczyt surowych plików JSON zebranych z API CityBikes/Nextbike Warszawa.
-- 2. Rozpakowanie zagnieżdżonej tablicy stacji za pomocą unnest(network.stations).
-- 3. Konwersja formatów i typów danych (timestampy, daty, typy numeryczne UINTEGER).
-- 4. Zapisanie danych w formacie kolumnowym Apache Parquet z partycjonowaniem dziennym (dt).
-- ==============================================================================

{{ config(
    materialized='external',
    location='data/bronze/veturilo/',
    options={
        "partition_by": "dt",
        "overwrite_or_ignore": true
    }
) }}

WITH raw_json AS (
    -- Krok 1: Wczytanie surowych JSON-ów i rozwinięcie tablicy 'stations'.
    -- Każdy plik JSON reprezentuje jeden zrzut stanu całego miasta w danej minucie.
    -- Klucz network.stations zawiera listę wszystkich ~350 stacji w Warszawie.
    SELECT unnest(network.stations) AS s
    FROM read_json_auto(
        'data/raw/veturilo/**/*.json',
        ignore_errors=true
    )
),

localized AS (
    SELECT
        -- 1. Bierzemy 16 znaków "YYYY-MM-DD HH:MM" (odrzucamy mikrosekundy i wadliwy ogon strefy)
        -- 2. Deklarujemy, że ten czas to UTC
        -- 3. Konwertujemy na czas lokalny Europe/Warsaw
        (CAST(left(replace(s.timestamp, 'T', ' '), 16) AS TIMESTAMP) 
            AT TIME ZONE 'UTC' 
            AT TIME ZONE 'Europe/Warsaw') AS ts,
        s
    FROM raw_json
)

SELECT
    -- Czas lokalny i poprawna data do partycjonowania (uwzględnia przesunięcie po północy)
    ts,
    ts::DATE                                     AS dt,

    -- Metadane stacji
    s.id::VARCHAR                                AS id,
    s.name::VARCHAR                              AS name,
    s.latitude::DOUBLE                           AS latitude,
    s.longitude::DOUBLE                          AS longitude,

    -- Stan stacji
    s.free_bikes::UINTEGER                       AS free_bikes,
    s.empty_slots::UINTEGER                      AS empty_slots,

    -- Identyfikatory numeryczne: TRY_CAST chroni przed crashowaniem runa przez stacje testowe/puste stringi
    TRY_CAST(s.extra.uid AS UINTEGER)            AS uid,
    TRY_CAST(s.extra.number AS UINTEGER)         AS number,
    TRY_CAST(s.extra.slots AS UINTEGER)          AS slots,

    -- Tablica identyfikatorów rowerów
    CAST(s.extra.bike_uids AS UINTEGER[])        AS bike_uids

FROM localized
-- Sortowanie gwarantuje powstanie dokładnie 1 pliku Parquet na partycję dzienną
ORDER BY dt, ts