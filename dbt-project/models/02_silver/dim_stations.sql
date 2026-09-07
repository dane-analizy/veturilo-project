-- ==============================================================================
-- MODEL: dim_stations.sql
-- WARSTWA: 02_Silver (Hurtownia danych - Medallion Architecture)
-- MATERIAŁIZACJA: external (zapis do pojedynczego pliku Parquet na dysku)
-- ŚCIEŻKA DOCELOWA: data/silver/dim_stations.parquet
--
-- CEL MODELU:
-- 1. Utworzenie tabeli wymiaru stacji (DimStations w modelu gwiazdy Kimballa).
-- 2. Odfiltrowanie powtarzających się co minutę metadanych stacji (DISTINCT).
-- 3. Zapewnienie stabilnego słownika stacji dla całej warstwy Silver i Gold.
-- ==============================================================================

{{ config(
    location='data/silver/dim_stations.parquet',
    options={
        "overwrite_or_ignore": true
    }
) }}

-- DISTINCT po wszystkich kolumnach usuwa duplikaty wynikające z tego,
-- że te same metadane stacji powtarzają się w każdym pomiarze minutowym.
SELECT DISTINCT
    id,                  -- UUID stacji z API (może ulec zmianie przy reinstalacji stacji)
    uid AS station_uid,  -- Stabilny, numeryczny identyfikator stacji (główny klucz obcy)
    name,                -- Czytelna nazwa stacji w terenie (np. "Metro Świętokrzyska")
    number,              -- Numer stacji widoczny na totemach Veturilo
    longitude,           -- Długość geograficzna (WGS84)
    latitude,            -- Szerokość geograficzna (WGS84)
    slots                -- Łączna pojemność stacji (liczba zamków/stojaków)

FROM {{ ref('bronze_veturilo') }}
ORDER BY longitude, latitude
