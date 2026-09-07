from pathlib import Path

import duckdb
import folium
import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from streamlit_folium import st_folium

# Wymuszamy użycie standardowego pythonowego typu object dla tekstów w Pandas.
# Bez tego Pandas na Pythonie 3.13 automatycznie próbuje konwertować teksty na typy PyArrow,
# co powoduje Segmentation Fault w bibliotece C++ PyArrow.
pd.options.future.infer_string = False
pd.options.mode.string_storage = "python"

PROJECT_DATA_DIR = Path(__file__).resolve().parent.parent / "veturilo_project" / "data"
LOGISTICS_PATH = PROJECT_DATA_DIR / "gold" / "mart_station_logistics_hourly.parquet"
OD_FLOWS_PATH = PROJECT_DATA_DIR / "gold" / "mart_station_od_flows_hourly.parquet"

# Konfiguracja układu strony Streamlit
st.set_page_config(page_title="Veturilo", layout="wide")


# 1. Tworzymy jedno wspólne połączenie i rejestrujemy widoki na marty Gold.
# Używamy @st.cache_resource, aby połączenie z DuckDB było współdzielone między wątkami/przebiegami.
@st.cache_resource
def get_db_connection():
    con = duckdb.connect()
    con.execute(
        f"CREATE OR REPLACE VIEW logistics_view AS SELECT * FROM read_parquet('{LOGISTICS_PATH}')"
    )
    con.execute(
        f"CREATE OR REPLACE VIEW od_flows_view AS SELECT * FROM read_parquet('{OD_FLOWS_PATH}')"
    )
    return con


# 2. Ładowanie katalogu stacji z martu tras Origin-Destination.
# Nie keszujemy tej funkcji za pomocą @st.cache_data, ponieważ zwracany obiekt DataFrame
# przy kolejnych odczytach z cache w środowisku wielowątkowym Streamlita potrafił powodować
# konflikty alokacji w bibliotece PyArrow i błędy Segmentation Fault.
def load_station_directory():
    con = get_db_connection()
    cursor = con.cursor()
    # WAŻNE: Używamy .fetchnumpy() zamiast .df() / .fetchdf(), ponieważ .df() konwertuje stringi
    # na typ ArrowString (string[pyarrow]). Pod Pythonem 3.13 powoduje to Segmentation Fault
    # w module string_arrow.py z powodu błędów kompatybilności binarnej PyArrow.
    # .fetchnumpy() zwraca standardowe typy Python/NumPy, które są w pełni stabilne.
    df = pd.DataFrame(
        cursor.execute(
            """
            SELECT DISTINCT
                start_station_uid AS station_uid,
                start_station_name AS name,
                start_latitude AS latitude,
                start_longitude AS longitude
            FROM od_flows_view
            WHERE start_station_uid IS NOT NULL
            UNION
            SELECT DISTINCT
                end_station_uid AS station_uid,
                end_station_name AS name,
                end_latitude AS latitude,
                end_longitude AS longitude
            FROM od_flows_view
            WHERE end_station_uid IS NOT NULL
            ORDER BY name
            """
        ).fetchnumpy()
    )
    cursor.close()
    return df


@st.cache_data
def load_station_logistics(station_uid: str) -> pd.DataFrame:
    con = get_db_connection()
    cursor = con.cursor()
    df = pd.DataFrame(
        cursor.execute(
            """
            SELECT hour_ts, outgoing_trips, incoming_trips, net_balance, station_role
            FROM logistics_view
            WHERE station_uid = ?
            ORDER BY hour_ts
            """,
            [station_uid],
        ).fetchnumpy()
    )
    cursor.close()
    df["hour_ts"] = pd.to_datetime(df["hour_ts"])
    return df


@st.cache_data
def load_destination_routes(station_uid: str) -> pd.DataFrame:
    con = get_db_connection()
    cursor = con.cursor()
    df = pd.DataFrame(
        cursor.execute(
            """
            SELECT
                end_station_name AS "Stacja docelowa",
                SUM(trips_count) AS "Przejazdy",
                MAX(distance_km) AS "Dystans (km)",
                ROUND(AVG(avg_duration_minutes), 1) AS "Śr. czas (min)"
            FROM od_flows_view
            WHERE start_station_uid = ?
              AND end_station_uid <> start_station_uid
            GROUP BY end_station_name
            ORDER BY "Przejazdy" DESC
            """,
            [station_uid],
        ).fetchnumpy()
    )
    cursor.close()
    return df


@st.cache_data
def load_selected_route(station_uid: str, destination_name: str) -> pd.DataFrame:
    con = get_db_connection()
    cursor = con.cursor()
    df = pd.DataFrame(
        cursor.execute(
            """
            SELECT
                start_station_name,
                start_latitude,
                start_longitude,
                end_station_name,
                end_latitude,
                end_longitude,
                SUM(trips_count) AS trips_count
            FROM od_flows_view
            WHERE start_station_uid = ?
              AND end_station_name = ?
            GROUP BY ALL
            """,
            [station_uid, destination_name],
        ).fetchnumpy()
    )
    cursor.close()
    return df


# Pobranie katalogu stacji z martu Gold
metadata = load_station_directory()

# Budowanie słowników wyszukiwania i posortowanej listy nazw stacji
uid_by_name = metadata.set_index("name")["station_uid"].to_dict()
name_by_uid = metadata.set_index("station_uid")["name"].to_dict()
station_names = sorted(metadata["name"].tolist())

# UI: Wybór stacji
selected_name = st.selectbox("Stacja", station_names)
selected_uid = uid_by_name[selected_name]

# UI: Mapa lokalizacji stacji
m = folium.Map(
    location=[metadata["latitude"].mean(), metadata["longitude"].mean()],
    zoom_start=11,
    tiles="OpenStreetMap",
)
for idx, row in metadata.iterrows():
    is_selected = row["station_uid"] == selected_uid
    folium.CircleMarker(
        location=[row["latitude"], row["longitude"]],
        radius=7,
        color="#e74c3c" if is_selected else "#3498db",
        fill=True,
        fill_color="#e74c3c" if is_selected else "#3498db",
        fill_opacity=1.0 if is_selected else 0.6,
        popup=folium.Popup(
            f"<b>{row['name']}</b><br>ID: {row['station_uid']}", max_width=200
        ),
    ).add_to(m)

# Renderujemy mapę przy użyciu st_folium.
# Używamy dynamicznego klucza (key=f"map_{selected_uid}"), aby Streamlit wygenerował mapę na nowo
# i wycentrował ją na nowo wybranej stacji po zmianie w selectboxie.
# Poprzednio powodowało to awarie, ponieważ PyArrow/Pandas alokowało pamięć w tle,
# ale po przejściu na .fetchnumpy() ten problem zniknął i st_folium działa w 100% stabilnie!
st_folium(
    m,
    use_container_width=True,
    height=500,
    returned_objects=[],
    key=f"map_{selected_uid}",
)

# Wykres godzinowych przepływów z martu Gold.
station_logistics = load_station_logistics(selected_uid)
logistics_fig = go.Figure()
logistics_fig.add_trace(
    go.Scatter(
        x=station_logistics["hour_ts"],
        y=station_logistics["outgoing_trips"],
        name="Wypożyczenia",
        mode="lines",
    )
)
logistics_fig.add_trace(
    go.Scatter(
        x=station_logistics["hour_ts"],
        y=station_logistics["incoming_trips"],
        name="Zwroty",
        mode="lines",
    )
)
logistics_fig.update_layout(
    title=f"Ruch godzinowy: {selected_name}",
    height=350,
    margin={"l": 0, "r": 0, "t": 40, "b": 0},
)
st.plotly_chart(logistics_fig, width="stretch", config={"displayModeBar": False})

# Tabela tras docelowych dla wybranej stacji, zasilana martem Gold.
st.subheader(f"Trasy docelowe ze stacji: {selected_name}")
destination_routes = load_destination_routes(selected_uid)
st.dataframe(destination_routes, hide_index=True, width="stretch")

# Mapa jednej relacji wybranej z tabeli O-D.
if not destination_routes.empty:
    destination_name = st.selectbox(
        "Trasa na mapie",
        destination_routes["Stacja docelowa"].tolist(),
    )
    selected_route = load_selected_route(selected_uid, destination_name)
    route = selected_route.iloc[0]
    route_map = folium.Map(
        location=[
            (route["start_latitude"] + route["end_latitude"]) / 2,
            (route["start_longitude"] + route["end_longitude"]) / 2,
        ],
        zoom_start=13,
        tiles="CartoDB positron",
    )
    folium.Marker(
        [route["start_latitude"], route["start_longitude"]],
        tooltip=f"Start: {route['start_station_name']}",
        icon=folium.Icon(color="green", icon="play"),
    ).add_to(route_map)
    folium.Marker(
        [route["end_latitude"], route["end_longitude"]],
        tooltip=f"Cel: {route['end_station_name']}",
        icon=folium.Icon(color="red", icon="flag"),
    ).add_to(route_map)
    folium.PolyLine(
        locations=[
            [route["start_latitude"], route["start_longitude"]],
            [route["end_latitude"], route["end_longitude"]],
        ],
        color="#e4572e",
        weight=6,
        opacity=0.8,
        tooltip=f"{int(route['trips_count'])} przejazdów",
    ).add_to(route_map)
    st_folium(
        route_map,
        use_container_width=True,
        height=500,
        returned_objects=[],
        key=f"route_map_{selected_uid}_{destination_name}",
    )
